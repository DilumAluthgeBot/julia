# This file is a part of Julia. License is MIT: https://julialang.org/license

module LineEdit

import ..REPL
using ..REPL: AbstractREPL, Options

using ..Terminals
import ..Terminals: raw!, width, height, clear_line, beep

import Base: ensureroom, show, AnyDict, position
using Base: something

using InteractiveUtils: InteractiveUtils

abstract type TextInterface end                # see interface immediately below
abstract type ModeState end                    # see interface below
abstract type HistoryProvider end
abstract type CompletionProvider end

export run_interface, Prompt, ModalInterface, transition, reset_state, edit_insert, keymap

@nospecialize # use only declared type signatures

const StringLike = Union{Char,String,SubString{String}}

# interface for TextInterface
function Base.getproperty(ti::TextInterface, name::Symbol)
    if name === :hp
        return getfield(ti, :hp)::HistoryProvider
    elseif name === :complete
        return getfield(ti, :complete)::CompletionProvider
    elseif name === :keymap_dict
        return getfield(ti, :keymap_dict)::Dict{Char,Any}
    end
    return getfield(ti, name)
end

struct ModalInterface <: TextInterface
    modes::Vector{TextInterface}
end

mutable struct Prompt <: TextInterface
    # A string or function to be printed as the prompt.
    prompt::Union{String,Function}
    # A string or function to be printed before the prompt. May not change the length of the prompt.
    # This may be used for changing the color, issuing other terminal escape codes, etc.
    prompt_prefix::Union{String,Function}
    # Same as prefix except after the prompt
    prompt_suffix::Union{String,Function}
    output_prefix::Union{String,Function}
    output_prefix_prefix::Union{String,Function}
    output_prefix_suffix::Union{String,Function}
    keymap_dict::Dict{Char,Any}
    repl::Union{AbstractREPL,Nothing}
    complete::CompletionProvider
    on_enter::Function
    on_done::Function
    hist::HistoryProvider  # TODO?: rename this `hp` (consistency with other TextInterfaces), or is the type-assert useful for mode(s)?
    sticky::Bool
end

show(io::IO, x::Prompt) = show(io, string("Prompt(\"", prompt_string(x.prompt), "\",...)"))


mutable struct MIState
    interface::ModalInterface
    active_module::Module
    previous_active_module::Module
    current_mode::TextInterface
    aborted::Bool
    mode_state::IdDict{TextInterface,ModeState}
    kill_ring::Vector{String}
    kill_idx::Int
    previous_key::Vector{Char}
    key_repeats::Int
    last_action::Symbol
    current_action::Symbol
    async_channel::Channel{Function}
    line_modify_lock::Base.ReentrantLock
    hint_generation_lock::Base.ReentrantLock
    n_keys_pressed::Int
end

MIState(i, mod, c, a, m) = MIState(i, mod, mod, c, a, m, String[], 0, Char[], 0, :none, :none, Channel{Function}(), Base.ReentrantLock(), Base.ReentrantLock(), 0)

const BufferLike = Union{MIState,ModeState,IOBuffer}
const State = Union{MIState,ModeState}

function show(io::IO, s::MIState)
    print(io, "MI State (", mode(s), " active)")
end

struct InputAreaState
    num_rows::Int64
    curs_row::Int64
end

mutable struct PromptState <: ModeState
    terminal::AbstractTerminal
    p::Prompt
    input_buffer::IOBuffer
    region_active::Symbol # :shift or :mark or :off
    hint::Union{String,Nothing}
    undo_buffers::Vector{IOBuffer}
    undo_idx::Int
    ias::InputAreaState
    # indentation of lines which do not include the prompt
    # if negative, the width of the prompt is used
    indent::Int
    refresh_lock::Threads.SpinLock
    # this would better be Threads.Atomic{Float64}, but not supported on some platforms
    beeping::Float64
    # this option is to detect when code is pasted in non-"bracketed paste mode" :
    last_newline::Float64 # register when last newline was entered
    # this option is to speed up output
    refresh_wait::Union{Timer,Nothing}
end

struct Modifiers
    shift::Bool
end
Modifiers() = Modifiers(false)

options(s::PromptState) =
    if isdefined(s.p, :repl) && isdefined(s.p.repl, :options)
        # we can't test isa(s.p.repl, LineEditREPL) as LineEditREPL is defined
        # in the REPL module
        s.p.repl.options::Options
    else
        REPL.GlobalOptions::Options
    end

function setmark(s::MIState, guess_region_active::Bool=true)
    refresh = set_action!(s, :setmark)
    s.current_action === :setmark && s.key_repeats > 0 && activate_region(s, :mark)
    mark(buffer(s))
    refresh && refresh_line(s)
    nothing
end

# the default mark is 0
getmark(s::BufferLike) = max(0, buffer(s).mark)

const Region = Pair{Int,Int}

_region(s::BufferLike) = getmark(s) => position(s)
region(s::BufferLike) = Pair(extrema(_region(s))...)

bufend(s::BufferLike) = buffer(s).size

axes(reg::Region) = first(reg)+1:last(reg)

content(s::BufferLike, reg::Region = 0=>bufend(s)) = String(buffer(s).data[axes(reg)])

function activate_region(s::PromptState, state::Symbol)
    @assert state in (:mark, :shift, :off)
    s.region_active = state
    nothing
end

activate_region(s::ModeState, state::Symbol) = false
deactivate_region(s::ModeState) = activate_region(s, :off)

is_region_active(s::PromptState) = s.region_active in (:shift, :mark)
is_region_active(s::ModeState) = false

region_active(s::PromptState) = s.region_active
region_active(s::ModeState) = :off


input_string(s::PromptState) = takestring!(copy(s.input_buffer))::String

input_string_newlines(s::PromptState) = count(c->(c == '\n'), input_string(s))
function input_string_newlines_aftercursor(s::PromptState)
    str = input_string(s)
    isempty(str) && return 0
    rest = str[nextind(str, position(s)):end]
    return count(c->(c == '\n'), rest)
end

struct EmptyCompletionProvider <: CompletionProvider end
struct EmptyHistoryProvider <: HistoryProvider end

reset_state(::EmptyHistoryProvider) = nothing

# Before, completions were always given as strings. But at least for backslash
# completions, it's nice to see what glyphs are available in the completion preview.
# To separate between what's shown in the preview list of possible matches, and what's
# actually completed, we introduce this struct.
struct NamedCompletion
    completion::String # what is actually completed, for example "\trianglecdot"
    name::String # what is displayed in lists of possible completions, for example "◬ \trianglecdot"
end

NamedCompletion(completion::String) = NamedCompletion(completion, completion)

complete_line(c::EmptyCompletionProvider, s; hint::Bool=false) = NamedCompletion[], "", true

# complete_line can be specialized for only two arguments, when the active module
# doesn't matter (e.g. Pkg does this)
complete_line(c::CompletionProvider, s, ::Module; hint::Bool=false) = complete_line(c, s; hint)

terminal(s::IO) = s
terminal(s::PromptState) = s.terminal


function beep(s::PromptState, duration::Real=options(s).beep_duration,
              blink::Real=options(s).beep_blink,
              maxduration::Real=options(s).beep_maxduration;
              colors=options(s).beep_colors,
              use_current::Bool=options(s).beep_use_current)
    isinteractive() || return # some tests fail on some platforms
    s.beeping = min(s.beeping + duration, maxduration)
    let colors = Base.copymutable(colors)
        errormonitor(@async begin
            trylock(s.refresh_lock) || return
            try
                orig_prefix = s.p.prompt_prefix
                use_current && push!(colors, prompt_string(orig_prefix))
                i = 0
                while s.beeping > 0.0
                    prefix = colors[mod1(i+=1, end)]
                    s.p.prompt_prefix = prefix
                    refresh_multi_line(s, beeping=true)
                    sleep(blink)
                    s.beeping -= blink
                end
                s.p.prompt_prefix = orig_prefix
                refresh_multi_line(s, beeping=true)
                s.beeping = 0.0
            finally
                unlock(s.refresh_lock)
            end
        end)
    end
    nothing
end

function cancel_beep(s::PromptState)
    # wait till beeping finishes
    while !trylock(s.refresh_lock)
        s.beeping = 0.0
        sleep(.05)
    end
    unlock(s.refresh_lock)
    nothing
end

beep(::ModeState) = nothing
cancel_beep(::ModeState) = nothing

for f in Union{Symbol,Expr}[
          :terminal, :on_enter, :add_history, :_buffer, :(Base.isempty),
          :replace_line, :refresh_multi_line, :input_string, :update_display_buffer,
          :empty_undo, :push_undo, :pop_undo, :options, :cancel_beep, :beep,
          :deactivate_region, :activate_region, :is_region_active, :region_active]
    @eval ($f)(s::MIState, args...) = $(f)(state(s), args...)
end

for f in [:edit_insert, :edit_insert_newline, :edit_backspace, :edit_move_left,
          :edit_move_right, :edit_move_word_left, :edit_move_word_right]
    @eval function ($f)(s::MIState, args...)
        set_action!(s, $(Expr(:quote, f)))
        $(f)(state(s), args...)
    end
end

const COMMAND_GROUPS =
    Dict(:movement    => [:edit_move_left, :edit_move_right, :edit_move_word_left, :edit_move_word_right,
                          :edit_move_up, :edit_move_down, :edit_exchange_point_and_mark],
         :deletion    => [:edit_clear, :edit_backspace, :edit_delete, :edit_werase,
                          :edit_delete_prev_word,
                          :edit_delete_next_word,
                          :edit_kill_line_forwards, :edit_kill_line_backwards, :edit_kill_region],
         :insertion   => [:edit_insert, :edit_insert_newline, :edit_yank],
         :replacement => [:edit_yank_pop, :edit_transpose_chars, :edit_transpose_words,
                          :edit_upper_case, :edit_lower_case, :edit_title_case, :edit_indent,
                          :edit_transpose_lines_up!, :edit_transpose_lines_down!],
         :copy        => [:edit_copy_region],
         :misc        => [:complete_line, :setmark, :edit_undo!, :edit_redo!])

const COMMAND_GROUP = Dict{Symbol,Symbol}(command=>group for (group, commands) in COMMAND_GROUPS for command in commands)
command_group(command::Symbol) = get(COMMAND_GROUP, command, :nogroup)
command_group(command::Function) = command_group(nameof(command))

# return true if command should keep active a region
function preserve_active(command::Symbol)
    command ∈ [:edit_indent, :edit_transpose_lines_down!, :edit_transpose_lines_up!]
end

# returns whether the "active region" status changed visibly,
# i.e. whether there should be a visual refresh
function set_action!(s::MIState, command::Symbol)
    # if a command is already running, don't update the current_action field,
    # as the caller is used as a helper function
    s.current_action === :unknown || return false

    active = region_active(s)

    ## record current action
    s.current_action = command

    ## handle activeness of the region
    if startswith(String(command), "shift_") # shift-move command
        if active !== :shift
            setmark(s) # s.current_action must already have been set
            activate_region(s, :shift)
            # NOTE: if the region was already active from a non-shift
            # move (e.g. ^Space^Space), the region is visibly changed
            return active !== :off # active status is reset
        end
    elseif !(preserve_active(command) ||
             command_group(command) === :movement && region_active(s) === :mark)
        # if we move after a shift-move, the region is de-activated
        # (e.g. like emacs behavior)
        deactivate_region(s)
        return active !== :off
    end
    false
end

set_action!(s, command::Symbol) = nothing

common_prefix(completions::Vector{NamedCompletion}) = common_prefix(map(x -> x.completion, completions))
function common_prefix(completions::Vector{String})
    ret = ""
    c1 = completions[1]
    isempty(c1) && return ret
    i = 1
    cc, nexti = iterate(c1, i)
    while true
        for c in completions
            (i > lastindex(c) || c[i] != cc) && return ret
        end
        ret = string(ret, cc)
        i >= lastindex(c1) && return ret
        i = nexti
        cc, nexti = iterate(c1, i)
    end
end

# This is the maximum number of completions that will be displayed in a single
# column, anything above that and multiple columns will be used. Note that this
# does not restrict column length when multiple columns are used.
const MULTICOLUMN_THRESHOLD = 5

show_completions(s::PromptState, completions::Vector{NamedCompletion}) = show_completions(s, map(x -> x.name, completions))

# Show available completions
function show_completions(s::PromptState, completions::Vector{String})
    # skip any lines of input after the cursor
    cmove_down(terminal(s), input_string_newlines_aftercursor(s))
    println(terminal(s))
    if any(Base.Fix1(occursin, '\n'), completions)
        foreach(Base.Fix1(println, terminal(s)), completions)
    else
        n = length(completions)
        colmax = 2 + maximum(length, completions; init=1) # n.b. length >= textwidth

        num_cols = min(cld(n, MULTICOLUMN_THRESHOLD),
                       max(div(width(terminal(s)), colmax), 1))

        entries_per_col = cld(n, num_cols)
        idx = 0
        for _ in 1:entries_per_col
            for col = 0:(num_cols-1)
                idx += 1
                idx > n && break
                cmove_col(terminal(s), colmax*col+1)
                print(terminal(s), completions[idx])
            end
            println(terminal(s))
        end
    end

    # make space for the prompt
    for i = 1:input_string_newlines(s)
        println(terminal(s))
    end
end

# Prompt Completions & Hints
function complete_line(s::MIState)
    set_action!(s, :complete_line)
    if complete_line(state(s), s.key_repeats, s.active_module)
        return refresh_line(s)
    else
        beep(s)
        return :ignore
    end
end

# Old complete_line return type: Vector{String},          String, Bool
# New complete_line return type: NamedCompletion{String}, String, Bool
#                            OR  NamedCompletion{String}, Region, Bool
#
# due to close coupling of the Pkg ReplExt `complete_line` can still return a vector of strings,
# so we convert those in this helper
function complete_line_named(c, s, args...; kwargs...)::Tuple{Vector{NamedCompletion},Region,Bool}
    r1, r2, should_complete = complete_line(c, s, args...; kwargs...)::Union{
        Tuple{Vector{String}, String, Bool},
        Tuple{Vector{NamedCompletion}, String, Bool},
        Tuple{Vector{NamedCompletion}, Region, Bool},
    }
    completions = (r1 isa Vector{String} ? map(NamedCompletion, r1) : r1)
    r = (r2 isa String ? (position(s)-sizeof(r2) => position(s)) : r2)
    completions, r, should_complete
end

# checks for a hint and shows it if appropriate.
# to allow the user to type even if hint generation is slow, the
# hint is generated on a worker thread, and only shown if the user hasn't
# pressed a key since the hint generation was requested
function check_show_hint(s::MIState)
    st = state(s)

    this_key_i = s.n_keys_pressed
    next_key_pressed() = @lock s.line_modify_lock s.n_keys_pressed > this_key_i
    function lock_clear_hint()
        @lock s.line_modify_lock begin
            next_key_pressed() || s.aborted || clear_hint(st) && refresh_line(s)
        end
    end

    if !options(st).hint_tab_completes || !eof(buffer(st))
        # only generate hints if enabled and at the end of the line
        # TODO: maybe show hints for insertions at other positions
        # Requires making space for them earlier in refresh_multi_line
        lock_clear_hint()
        return
    end
    t_completion = Threads.@spawn :default begin
        named_completions, reg, should_complete = nothing, nothing, nothing

        # only allow one task to generate hints at a time and check around lock
        # if the user has pressed a key since the hint was requested, to skip old completions
        next_key_pressed() && return
        @lock s.hint_generation_lock begin
            next_key_pressed() && return
            named_completions, reg, should_complete = try
                complete_line_named(st.p.complete, st, s.active_module; hint = true)
            catch
                lock_clear_hint()
                return
            end
        end
        next_key_pressed() && return

        completions = map(x -> x.completion, named_completions)
        if isempty(completions)
            lock_clear_hint()
            return
        end
        # Don't complete for single chars, given e.g. `x` completes to `xor`
        if reg.second - reg.first > 1 && should_complete
            singlecompletion = length(completions) == 1
            p = singlecompletion ? completions[1] : common_prefix(completions)
            if singlecompletion || p in completions # i.e. complete `@time` even though `@time_imports` etc. exists
                # The completion `p` and the region `reg` may not share the same initial
                # characters, for instance when completing to subscripts or superscripts.
                # So, in general, make sure that the hint starts at the correct position by
                # incrementing its starting position by as many characters as the input.
                maxind = lastindex(p)
                startind = sizeof(content(s, reg))
                if startind ≤ maxind # completion on a complete name returns itself so check that there's something to hint
                    # index of p from which to start providing the hint
                    startind = nextind(p, startind)
                    hint = p[startind:end]
                    next_key_pressed() && return
                    @lock s.line_modify_lock begin
                        if !s.aborted
                            state(s).hint = hint
                            refresh_line(s)
                        end
                    end
                    return
                end
            end
        end
        lock_clear_hint()
    end
    Base.errormonitor(t_completion)
    return
end

function clear_hint(s::ModeState)
    if !isnothing(s.hint)
        s.hint = "" # don't set to nothing here. That will be done in `maybe_show_hint`
        return true # indicate maybe_show_hint has work to do
    else
        return false
    end
end

function complete_line(s::PromptState, repeats::Int, mod::Module; hint::Bool=false)
    completions, reg, should_complete = complete_line_named(s.p.complete, s, mod; hint)
    isempty(completions) && return false
    if !should_complete
        # should_complete is false for cases where we only want to show
        # a list of possible completions but not complete, e.g. foo(\t
        show_completions(s, completions)
    elseif length(completions) == 1
        # Replace word by completion
        push_undo(s)
        edit_splice!(s, reg, completions[1].completion)
    else
        p = common_prefix(completions)
        partial = content(s, reg.first => min(bufend(s), reg.first + sizeof(p)))
        if !isempty(p) && p != partial
            # All possible completions share the same prefix, so we might as
            # well complete that.
            push_undo(s)
            edit_splice!(s, reg, p)
        elseif repeats > 0
            show_completions(s, completions)
        end
    end
    return true
end

function clear_input_area(terminal::AbstractTerminal, s::PromptState)
    if s.refresh_wait !== nothing
        close(s.refresh_wait)
        s.refresh_wait = nothing
    end
    _clear_input_area(terminal, s.ias)
    s.ias = InputAreaState(0, 0)
end
clear_input_area(terminal::AbstractTerminal, s::ModeState) = (_clear_input_area(terminal, s.ias); s.ias = InputAreaState(0, 0))
clear_input_area(s::ModeState) = clear_input_area(s.terminal, s)

function _clear_input_area(terminal::AbstractTerminal, state::InputAreaState)
    # Go to the last line
    if state.curs_row < state.num_rows
        cmove_down(terminal, state.num_rows - state.curs_row)
    end

    # Clear lines one by one going up
    for j = 2:state.num_rows
        clear_line(terminal)
        cmove_up(terminal)
    end

    # Clear top line
    clear_line(terminal)
    nothing
end

prompt_string(s::PromptState) = prompt_string(s.p)
prompt_string(p::Prompt) = prompt_string(p.prompt)
prompt_string(s::AbstractString) = s
prompt_string(f::Function) = Base.invokelatest(f)

function maybe_show_hint(s::PromptState)
    isa(s.hint, String) || return nothing
    # The hint being "" then nothing is used to first clear a previous hint, then skip printing the hint
    if isempty(s.hint)
        s.hint = nothing
    else
        Base.printstyled(terminal(s), s.hint, color=:light_black)
        cmove_left(terminal(s), textwidth(s.hint))
        s.hint = "" # being "" signals to do one clear line remainder to clear the hint next time the screen is refreshed
    end
    return nothing
end

function refresh_multi_line(s::PromptState; kw...)
    if s.refresh_wait !== nothing
        close(s.refresh_wait)
        s.refresh_wait = nothing
    end
    if s.hint isa String
        # clear remainder of line which is unknown here if it had a hint before unbeknownst to refresh_multi_line
        # the clear line cannot be printed each time because it would break column movement
        print(terminal(s), "\e[0K")
    end
    r = refresh_multi_line(terminal(s), s; kw...)
    maybe_show_hint(s) # now maybe write the hint back to the screen
    return r
end
refresh_multi_line(s::ModeState; kw...) = refresh_multi_line(terminal(s), s; kw...)
refresh_multi_line(termbuf::TerminalBuffer, s::ModeState; kw...) = refresh_multi_line(termbuf, terminal(s), s; kw...)
refresh_multi_line(termbuf::TerminalBuffer, term, s::ModeState; kw...) = (@assert term === terminal(s); refresh_multi_line(termbuf,s; kw...))

function refresh_multi_line(termbuf::TerminalBuffer, terminal::UnixTerminal, buf::IOBuffer,
                            state::InputAreaState, prompt = "";
                            indent::Int = 0, region_active::Bool = false)
    _clear_input_area(termbuf, state)

    cols = width(terminal)
    rows = height(terminal)
    curs_row = -1 # relative to prompt (1-based)
    curs_pos = -1 # 1-based column position of the cursor
    cur_row = 0   # count of the number of rows
    buf_pos = position(buf)
    line_pos = buf_pos
    regstart, regstop = region(buf)
    written = 0
    @static if Sys.iswindows()
        writer = Terminals.pipe_writer(terminal)
        if writer isa Base.TTY && !Base.ispty(writer)::Bool
            _reset_console_mode(writer.handle)
        end
    end
    # Write out the prompt string
    lindent = write_prompt(termbuf, prompt, hascolor(terminal))::Int
    # Count the '\n' at the end of the line if the terminal emulator does (specific to DOS cmd prompt)
    miscountnl = @static if Sys.iswindows()
        reader = Terminals.pipe_reader(terminal)
        reader isa Base.TTY && !Base.ispty(reader)::Bool
    else false end

    # Now go through the buffer line by line
    seek(buf, 0)
    moreinput = true # add a blank line if there is a trailing newline on the last line
    lastline = false # indicates when to stop printing lines, even when there are potentially
                     # more (for the case where rows is too small to print everything)
                     # Note: when there are too many lines for rows, we still print the first lines
                     # even if they are going to not be visible in the end: for simplicity, but
                     # also because it does the 'right thing' when the window is resized
    while moreinput
        line = readline(buf, keep=true)
        moreinput = endswith(line, "\n")
        if rows == 1 && line_pos <= sizeof(line) - moreinput
            # we special case rows == 1, as otherwise by the time the cursor is seen to
            # be in the current line, it's too late to chop the '\n' away
            lastline = true
            curs_row = 1
            curs_pos = lindent + line_pos
        end
        if moreinput && lastline # we want to print only one "visual" line, so
            line = chomp(line)   # don't include the trailing "\n"
        end
        # We need to deal with on-screen characters, so use textwidth to compute occupied columns
        llength = textwidth(line)
        slength = sizeof(line)
        cur_row += 1
        # lwrite: what will be written to termbuf
        lwrite = region_active ? highlight_region(line, regstart, regstop, written, slength) :
                                 line
        written += slength
        cmove_col(termbuf, lindent + 1)
        write(termbuf, lwrite)
        # We expect to be line after the last valid output line (due to
        # the '\n' at the end of the previous line)
        if curs_row == -1
            line_pos -= slength # '\n' gets an extra pos
            # in this case, we haven't yet written the cursor position
            if line_pos < 0 || !moreinput
                num_chars = line_pos >= 0 ?
                                llength :
                                textwidth(line[1:prevind(line, line_pos + slength + 1)])
                curs_row, curs_pos = divrem(lindent + num_chars - 1, cols)
                curs_row += cur_row
                curs_pos += 1
                # There's an issue if the cursor is after the very right end of the screen. In that case we need to
                # move the cursor to the next line, and emit a newline if needed
                if curs_pos == cols
                    # only emit the newline if the cursor is at the end of the line we're writing
                    if line_pos == 0
                        write(termbuf, "\n")
                        cur_row += 1
                    end
                    curs_row += 1
                    curs_pos = 0
                    cmove_col(termbuf, 1)
                end
            end
        end
        cur_row += div(max(lindent + llength + miscountnl - 1, 0), cols)
        lindent = indent < 0 ? lindent : indent

        lastline && break
        if curs_row >= 0 && cur_row + 1 >= rows &&             # when too many lines,
                            cur_row - curs_row + 1 >= rows ÷ 2 # center the cursor
            lastline = true
        end
    end
    seek(buf, buf_pos)

    # Let's move the cursor to the right position
    # The line first
    n = cur_row - curs_row
    if n > 0
        cmove_up(termbuf, n)
    end

    #columns are 1 based
    cmove_col(termbuf, curs_pos + 1)
    # Updated cur_row,curs_row
    return InputAreaState(cur_row, curs_row)
end

function highlight_region(lwrite::Union{String,SubString{String}}, regstart::Int, regstop::Int, written::Int, slength::Int)
    if written <= regstop <= written+slength
        i = thisind(lwrite, regstop-written)
        lwrite = lwrite[1:i] * Base.disable_text_style[:reverse] * lwrite[nextind(lwrite, i):end]
    end
    if written <= regstart <= written+slength
        i = thisind(lwrite, regstart-written)
        lwrite = lwrite[1:i] * Base.text_colors[:reverse] * lwrite[nextind(lwrite, i):end]
    end
    return lwrite
end

function refresh_multi_line(terminal::UnixTerminal, args...; kwargs...)
    outbuf = IOBuffer()
    termbuf = TerminalBuffer(outbuf)
    ret = refresh_multi_line(termbuf, terminal, args...;kwargs...)
    # Output the entire refresh at once
    write(terminal, take!(outbuf))
    flush(terminal)
    return ret
end


# Edit functionality
is_non_word_char(c::Char) = c in """ \t\n\"\\'`@\$><=:;|&{}()[].,+-*/?%^~"""

function reset_key_repeats(f::Function, s::MIState)
    key_repeats_sav = s.key_repeats
    try
        s.key_repeats = 0
        return f()
    finally
        s.key_repeats = key_repeats_sav
    end
end

function edit_exchange_point_and_mark(s::MIState)
    set_action!(s, :edit_exchange_point_and_mark)
    return edit_exchange_point_and_mark(buffer(s)) ? refresh_line(s) : false
end

function edit_exchange_point_and_mark(buf::IOBuffer)
    m = getmark(buf)
    m == position(buf) && return false
    mark(buf)
    seek(buf, m)
    return true
end

char_move_left(s::PromptState) = char_move_left(s.input_buffer)
function char_move_left(buf::IOBuffer)
    while position(buf) > 0
        seek(buf, position(buf)-1)
        c = peek(buf)
        (((c & 0x80) == 0) || ((c & 0xc0) == 0xc0)) && break
    end
    pos = position(buf)
    c = read(buf, Char)
    seek(buf, pos)
    return c
end

function edit_move_left(buf::IOBuffer)
    if position(buf) > 0
        #move to the next base UTF8 character to the left
        while true
            c = char_move_left(buf)
            if textwidth(c) != 0 || c == '\n' || position(buf) == 0
                break
            end
        end
        return true
    end
    return false
end

edit_move_left(s::PromptState) = edit_move_left(s.input_buffer) ? refresh_line(s) : false

function edit_move_word_left(s::PromptState)
    if position(s) > 0
        char_move_word_left(s.input_buffer)
        return refresh_line(s)
    end
    return nothing
end

char_move_right(s::MIState) = char_move_right(buffer(s))
function char_move_right(buf::IOBuffer)
    return !eof(buf) && read(buf, Char)
end

function char_move_word_right(buf::IOBuffer, is_delimiter::Function=is_non_word_char)
    while !eof(buf) && is_delimiter(char_move_right(buf))
    end
    while !eof(buf)
        pos = position(buf)
        if is_delimiter(char_move_right(buf))
            seek(buf, pos)
            break
        end
    end
end

function char_move_word_left(buf::IOBuffer, is_delimiter::Function=is_non_word_char)
    while position(buf) > 0 && is_delimiter(char_move_left(buf))
    end
    while position(buf) > 0
        pos = position(buf)
        if is_delimiter(char_move_left(buf))
            seek(buf, pos)
            break
        end
    end
end

char_move_word_right(s::Union{MIState,ModeState}) = char_move_word_right(buffer(s))
char_move_word_left(s::Union{MIState,ModeState}) = char_move_word_left(buffer(s))

function edit_move_right(buf::IOBuffer)
    if !eof(buf)
        # move to the next base UTF8 character to the right
        while true
            c = char_move_right(buf)
            eof(buf) && break
            pos = position(buf)
            nextc = read(buf,Char)
            seek(buf,pos)
            (textwidth(nextc) != 0 || nextc == '\n') && break
        end
        return true
    end
    return false
end
function edit_move_right(m::MIState)
    s = state(m)
    buf = s.input_buffer
    if edit_move_right(s.input_buffer)
        refresh_line(s)
        return true
    else
        completions, reg, should_complete = complete_line(s.p.complete, s, m.active_module)
        if should_complete && eof(buf) && length(completions) == 1 && reg.second - reg.first > 1
            # Replace word by completion
            prev_pos = position(s)
            push_undo(s)
            edit_splice!(s, (prev_pos - reg.second + reg.first) => prev_pos, completions[1].completion)
            refresh_line(state(s))
            return true
        else
            return false
        end
    end
end

function edit_move_word_right(s::PromptState)
    if !eof(s.input_buffer)
        char_move_word_right(s)
        return refresh_line(s)
    end
    return nothing
end

## Move line up/down
# Querying the terminal is expensive, memory access is cheap
# so to find the current column, we find the offset for the start
# of the line.

function edit_move_up(buf::IOBuffer)
    npos = findprev(isequal(UInt8('\n')), buf.data, position(buf))
    npos === nothing && return false # we're in the first line
    # We're interested in character count, not byte count
    offset = length(content(buf, npos => position(buf)))
    npos2 = something(findprev(isequal(UInt8('\n')), buf.data, npos-1), 0)
    seek(buf, npos2)
    for _ = 1:offset
        pos = position(buf)
        if read(buf, Char) == '\n'
            seek(buf, pos)
            break
        end
    end
    return true
end
function edit_move_up(s::MIState)
    set_action!(s, :edit_move_up)
    changed = edit_move_up(buffer(s))
    changed && refresh_line(s)
    return changed
end

function edit_move_down(buf::IOBuffer)
    npos = something(findprev(isequal(UInt8('\n')), buf.data[1:buf.size], position(buf)), 0)
    # We're interested in character count, not byte count
    offset = length(String(buf.data[(npos+1):(position(buf))]))
    npos2 = findnext(isequal(UInt8('\n')), buf.data[1:buf.size], position(buf)+1)
    if npos2 === nothing #we're in the last line
        return false
    end
    seek(buf, npos2)
    for _ = 1:offset
        pos = position(buf)
        if eof(buf) || read(buf, Char) == '\n'
            seek(buf, pos)
            break
        end
    end
    return true
end
function edit_move_down(s::MIState)
    set_action!(s, :edit_move_down)
    changed = edit_move_down(buffer(s))
    changed && refresh_line(s)
    return changed
end

function edit_shift_move(s::MIState, move_function::Function)
    @assert command_group(move_function) === :movement
    set_action!(s, Symbol(:shift_, move_function))
    return move_function(s)
end


# splice! for IOBuffer: convert from close-open region to index, update the size,
# and keep the cursor position and mark stable with the text
# returns the removed portion as a String
function edit_splice!(s::BufferLike, r::Region=region(s), ins::String = ""; rigid_mark::Bool=true)
    A, B = first(r), last(r)
    A >= B && isempty(ins) && return ins
    buf = buffer(s)
    pos = position(buf) # n.b. position(), etc, are 0-indexed
    adjust_pos = true
    if A <= pos < B
        seek(buf, A)
    elseif B <= pos
        seek(buf, pos - B + A)
    else
        adjust_pos = false
    end
    mark = buf.mark
    if mark != -1
        if A < mark < B || A == mark == B
            # rigid_mark is used only if the mark is strictly "inside"
            # the region, or the region is empty and the mark is at the boundary
            mark = rigid_mark ? A : A + sizeof(ins)
        elseif mark >= B
            mark += sizeof(ins) - B + A
        end
        buf.mark = -1
    end
    # Implement ret = splice!(buf.data, A+1:B, codeunits(ins)) for a stream
    pos = position(buf)
    seek(buf, A)
    ret = read(buf, A >= B ? 0 : B - A)
    trail = read(buf)
    seek(buf, A)
    write(buf, ins)
    write(buf, trail)
    truncate(buf, position(buf))
    seek(buf, pos + (adjust_pos ? sizeof(ins) : 0))
    buf.mark = mark
    return String(ret)
end

edit_splice!(s::MIState, ins::AbstractString) = edit_splice!(s, region(s), ins)

function edit_insert(s::PromptState, c::StringLike)
    push_undo(s)
    buf = s.input_buffer

    if ! options(s).auto_indent_bracketed_paste
        pos = position(buf)
        if pos > 0
            if buf.data[pos] != _space && string(c) != " "
                options(s).auto_indent_tmp_off = false
            end
            if buf.data[pos] == _space
                #tabulators are already expanded to space
                #this expansion may take longer than auto_indent_time_threshold which breaks the timing
                s.last_newline = time()
            else
                #if characters after new line are coming in very fast
                #its probably copy&paste => switch auto-indent off for the next coming new line
                if ! options(s).auto_indent_tmp_off && time() - s.last_newline < options(s).auto_indent_time_threshold
                    options(s).auto_indent_tmp_off = true
                end
            end
        end
    end

    old_wait = s.refresh_wait !== nothing
    if old_wait
        close(s.refresh_wait)
        s.refresh_wait = nothing
    end
    str = string(c)
    edit_insert(buf, str)
    if '\n' in str
        refresh_line(s)
    else
        after = options(s).auto_refresh_time_delay
        termbuf = terminal(s)
        w = width(termbuf)
        offset = s.ias.curs_row == 1 || s.indent < 0 ?
            sizeof(prompt_string(s.p.prompt)::String) : s.indent
        offset += position(buf) - beginofline(buf) # size of current line
        spinner = '\0'
        delayup = !eof(buf) || old_wait
        if offset + textwidth(str) <= w && !(after == 0 && delayup)
            # Avoid full update when appending characters to the end
            # and an update of curs_row isn't necessary (conservatively estimated)
            write(termbuf, str)
            spinner = ' ' # temporarily clear under the cursor
        elseif after == 0
            refresh_line(s)
            delayup = false
        else # render a spinner for each key press
            if old_wait || length(str) != 1
                spinner = spin_seq[mod1(position(buf) - w, length(spin_seq))]
            else
                spinner = str[end]
            end
            delayup = true
        end
        if delayup
            if spinner != '\0'
                write(termbuf, spinner)
                cmove_left(termbuf)
            end
            s.refresh_wait = Timer(after) do t
                s.refresh_wait === t || return
                s.refresh_wait = nothing
                refresh_line(s)
            end
        end
    end
    nothing
end
const spin_seq = ("⋯", "⋱", "⋮", "⋰")

function edit_insert(buf::IOBuffer, c::StringLike)
    if eof(buf)
        return write(buf, c)
    else
        s = string(c)
        edit_splice!(buf, position(buf) => position(buf), s)
        return sizeof(s)
    end
end

# align: number of ' ' to insert after '\n'
# if align < 0: align like line above
function edit_insert_newline(s::PromptState, align::Int = 0 - options(s).auto_indent)
    push_undo(s)
    buf = buffer(s)
    autoindent = align < 0
    if autoindent && ! options(s).auto_indent_tmp_off
        beg = beginofline(buf)
        align = min(something(findnext(_notspace, buf.data[beg+1:buf.size], 1), 0) - 1,
                    position(buf) - beg) # indentation must not increase
        align < 0 && (align = buf.size-beg)
    #else
    #    align = 0
    end
    align < 0 && (align = 0)
    edit_insert(buf, '\n' * ' '^align)
    refresh_line(s)
    # updating s.last_newline should happen after refresh_line(s) which can take
    # an unpredictable amount of time and makes "paste detection" unreliable
    if ! options(s).auto_indent_bracketed_paste
        s.last_newline = time()
    end
    nothing
end

# align: delete up to 4 spaces to align to a multiple of 4 chars
# adjust: also delete spaces on the right of the cursor to try to keep aligned what is
# on the right
function edit_backspace(s::PromptState, align::Bool=options(s).backspace_align,
                        adjust::Bool=options(s).backspace_adjust)
    push_undo(s)
    if edit_backspace(buffer(s), align, adjust)
        return refresh_line(s)
    else
        pop_undo(s)
        return beep(s)
    end
end

const _newline =  UInt8('\n')
const _space = UInt8(' ')

_notspace(c) = c != _space

beginofline(buf::IOBuffer, pos::Int=position(buf)) = something(findprev(isequal(_newline), buf.data, pos), 0)

function endofline(buf::IOBuffer, pos::Int=position(buf))
    eol = findnext(isequal(_newline), buf.data[pos+1:buf.size], 1)
    eol === nothing ? buf.size : pos + eol - 1
end

function edit_backspace(buf::IOBuffer, align::Bool=false, adjust::Bool=false)
    !align && adjust &&
        throw(DomainError((align, adjust),
                          "if `adjust` is `true`, `align` must be `true`"))
    oldpos = position(buf)
    oldpos == 0 && return false
    c = char_move_left(buf)
    newpos = position(buf)
    if align && c == ' ' # maybe delete multiple spaces
        beg = beginofline(buf, newpos)
        align = textwidth(String(buf.data[1+beg:newpos])) % 4
        nonspace = something(findprev(_notspace, buf.data, newpos), 0)
        if newpos - align >= nonspace
            newpos -= align
            seek(buf, newpos)
            if adjust
                spaces = something(findnext(_notspace, buf.data[newpos+2:buf.size], 1), 0)
                oldpos = spaces == 0 ? buf.size :
                    buf.data[newpos+1+spaces] == _newline ? newpos+spaces :
                    newpos + min(spaces, 4)
            end
        end
    end
    edit_splice!(buf, newpos => oldpos)
    return true
end

function edit_delete(s::MIState)
    set_action!(s, :edit_delete)
    push_undo(s)
    if edit_delete(buffer(s))
        return refresh_line(s)
    else
        pop_undo(s)
        return beep(s)
    end
end

function edit_delete(buf::IOBuffer)
    eof(buf) && return false
    oldpos = position(buf)
    char_move_right(buf)
    edit_splice!(buf, oldpos => position(buf))
    return true
end

function edit_werase(buf::IOBuffer)
    pos1 = position(buf)
    char_move_word_left(buf, isspace)
    pos0 = position(buf)
    return edit_splice!(buf, pos0 => pos1)
end

function edit_werase(s::MIState)
    set_action!(s, :edit_werase)
    push_undo(s)
    if push_kill!(s, edit_werase(buffer(s)), rev=true)
        return refresh_line(s)
    else
        pop_undo(s)
        return :ignore
    end
end

function edit_delete_prev_word(buf::IOBuffer)
    pos1 = position(buf)
    char_move_word_left(buf)
    pos0 = position(buf)
    return edit_splice!(buf, pos0 => pos1)
end

function edit_delete_prev_word(s::MIState)
    set_action!(s, :edit_delete_prev_word)
    push_undo(s)
    if push_kill!(s, edit_delete_prev_word(buffer(s)), rev=true)
        return refresh_line(s)
    else
        pop_undo(s)
        return :ignore
    end
end

function edit_delete_next_word(buf::IOBuffer)
    pos0 = position(buf)
    char_move_word_right(buf)
    pos1 = position(buf)
    return edit_splice!(buf, pos0 => pos1)
end

function edit_delete_next_word(s::MIState)
    set_action!(s, :edit_delete_next_word)
    push_undo(s)
    if push_kill!(s, edit_delete_next_word(buffer(s)))
        return refresh_line(s)
    else
        pop_undo(s)
        return :ignore
    end
end

function edit_yank(s::MIState)
    set_action!(s, :edit_yank)
    if isempty(s.kill_ring)
        beep(s)
        return :ignore
    end
    setmark(s) # necessary for edit_yank_pop
    push_undo(s)
    edit_insert(buffer(s), s.kill_ring[mod1(s.kill_idx, end)])
    return refresh_line(s)
end

function edit_yank_pop(s::MIState, require_previous_yank::Bool=true)
    set_action!(s, :edit_yank_pop)
    repeat = s.last_action ∈ (:edit_yank, :edit_yank_pop)
    if require_previous_yank && !repeat || isempty(s.kill_ring)
        beep(s)
        return :ignore
    else
        require_previous_yank || repeat || setmark(s)
        push_undo(s)
        edit_splice!(s, s.kill_ring[mod1(s.kill_idx -= 1, end)])
        return refresh_line(s)
    end
end

function push_kill!(s::MIState, killed::String, concat::Bool = s.key_repeats > 0; rev::Bool=false)
    isempty(killed) && return false
    if concat && !isempty(s.kill_ring)
        s.kill_ring[end] = rev ?
            killed * s.kill_ring[end] : # keep expected order for backward deletion
            s.kill_ring[end] * killed
    else
        push!(s.kill_ring, killed)
        length(s.kill_ring) > options(s).kill_ring_max && popfirst!(s.kill_ring)
    end
    s.kill_idx = lastindex(s.kill_ring)
    return true
end

function edit_kill_line(s::MIState, backwards::Bool=false)
    buf = buffer(s)
    if backwards
        set_action!(s, :edit_kill_line_backwards)
        pos = beginofline(buf)
        endpos = position(buf)
        pos == endpos && pos > 0 && (pos -= 1)
    else
        set_action!(s, :edit_kill_line_forwards)
        pos = position(buf)
        endpos = endofline(buf)
        endpos == pos && buf.size > pos && (endpos += 1)
    end
    push_undo(s)
    if push_kill!(s, edit_splice!(s, pos => endpos); rev=backwards)
        return refresh_line(s)
    else
        pop_undo(s)
        beep(s)
        return :ignore
    end
end

edit_kill_line_forwards(s::MIState) = edit_kill_line(s, false)
edit_kill_line_backwards(s::MIState) = edit_kill_line(s, true)

function edit_copy_region(s::MIState)
    set_action!(s, :edit_copy_region)
    buf = buffer(s)
    push_kill!(s, content(buf, region(buf)), false) || return :ignore
    if options(s).region_animation_duration > 0.0
        edit_exchange_point_and_mark(s)
        sleep(options(s).region_animation_duration)
        edit_exchange_point_and_mark(s)
    end
    nothing
end

function edit_kill_region(s::MIState)
    set_action!(s, :edit_kill_region)
    push_undo(s)
    if push_kill!(s, edit_splice!(s), false)
        return refresh_line(s)
    else
        pop_undo(s)
        return :ignore
    end
end

function edit_transpose_chars(s::MIState)
    set_action!(s, :edit_transpose_chars)
    push_undo(s)
    return edit_transpose_chars(buffer(s)) ? refresh_line(s) : pop_undo(s)
end

function edit_transpose_chars(buf::IOBuffer)
    # Moving left but not transpoing anything is intentional, and matches Emacs's behavior
    eof(buf) && position(buf) !== 0 && char_move_left(buf)
    position(buf) == 0 && return false
    char_move_left(buf)
    pos = position(buf)
    a, b = read(buf, Char), read(buf, Char)
    seek(buf, pos)
    write(buf, b, a)
    return true
end

function edit_transpose_words(s::MIState)
    set_action!(s, :edit_transpose_words)
    push_undo(s)
    return edit_transpose_words(buffer(s)) ? refresh_line(s) : pop_undo(s)
end

function edit_transpose_words(buf::IOBuffer, mode::Symbol=:emacs)
    mode in [:readline, :emacs] ||
        throw(ArgumentError("`mode` must be `:readline` or `:emacs`"))
    pos = position(buf)
    if mode === :emacs
        char_move_word_left(buf)
        char_move_word_right(buf)
    end
    char_move_word_right(buf)
    e2 = position(buf)
    char_move_word_left(buf)
    b2 = position(buf)
    char_move_word_left(buf)
    b1 = position(buf)
    char_move_word_right(buf)
    e1 = position(buf)
    e1 >= b2 && (seek(buf, pos); return false)
    word2 = edit_splice!(buf, b2 => e2, content(buf, b1 => e1))
    edit_splice!(buf, b1 => e1, word2)
    seek(buf, e2)
    return true
end


# swap all lines intersecting the region with line above
function edit_transpose_lines_up!(buf::IOBuffer, reg::Region)
    b2 = beginofline(buf, first(reg))
    b2 == 0 && return false
    b1 = beginofline(buf, b2-1)
    # we do in this order so that the buffer's position is maintained in current line
    line1 = edit_splice!(buf, b1 => b2) # delete whole previous line
    line1 = '\n'*line1[1:end-1] # don't include the final '\n'
    pos = position(buf) # save pos in case it's at the end of line
    b = endofline(buf, last(reg) - b2 + b1) # b2-b1 is the size of the removed line1
    edit_splice!(buf, b => b, line1)
    seek(buf, pos)
    return true
end

# swap all lines intersecting the region with line below
function edit_transpose_lines_down!(buf::IOBuffer, reg::Region)
    e1 = endofline(buf, last(reg))
    e1 == buf.size && return false
    e2 = endofline(buf, e1+1)
    line2 = edit_splice!(buf, e1 => e2) # delete whole next line
    line2 = line2[2:end]*'\n' # don't include leading '\n'
    b = beginofline(buf, first(reg))
    edit_splice!(buf, b => b, line2, rigid_mark=false)
    return true
end

# return the region if active, or the current position as a Region otherwise
region_if_active(s::MIState)::Region = is_region_active(s) ? region(s) : position(s)=>position(s)

function edit_transpose_lines_up!(s::MIState)
    set_action!(s, :edit_transpose_lines_up!)
    if edit_transpose_lines_up!(buffer(s), region_if_active(s))
        return refresh_line(s)
    else
        # beeping would be too noisy here
        return :ignore
    end
end

function edit_transpose_lines_down!(s::MIState)
    set_action!(s, :edit_transpose_lines_down!)
    if edit_transpose_lines_down!(buffer(s), region_if_active(s))
        return refresh_line(s)
    else
        return :ignore
    end
end

function edit_upper_case(s::BufferLike)
    set_action!(s, :edit_upper_case)
    return edit_replace_word_right(s, uppercase)
end
function edit_lower_case(s::BufferLike)
    set_action!(s, :edit_lower_case)
    return edit_replace_word_right(s, lowercase)
end
function edit_title_case(s::BufferLike)
    set_action!(s, :edit_title_case)
    return edit_replace_word_right(s, titlecase)
end

function edit_replace_word_right(s::Union{MIState,ModeState}, replace::Function)
    push_undo(s)
    return edit_replace_word_right(buffer(s), replace) ? refresh_line(s) : pop_undo(s)
end

function edit_replace_word_right(buf::IOBuffer, replace::Function)
    # put the cursor at the beginning of the next word
    skipchars(is_non_word_char, buf)
    b = position(buf)
    char_move_word_right(buf)
    e = position(buf)
    e == b && return false
    edit_splice!(buf, b => e, replace(content(buf, b => e)))
    return true
end

edit_clear(buf::IOBuffer) = truncate(buf, 0)

function edit_clear(s::MIState)
    set_action!(s, :edit_clear)
    push_undo(s)
    if push_kill!(s, edit_splice!(s, 0 => bufend(s)), false)
        return refresh_line(s)
    else
        pop_undo(s)
        return :ignore
    end
end

function replace_line(s::PromptState, l::IOBuffer)
    empty_undo(s)
    s.input_buffer = copy(l)
    deactivate_region(s)
    nothing
end

function replace_line(s::PromptState, l::Union{String,SubString{String}}, keep_undo::Bool=false)
    keep_undo || empty_undo(s)
    s.input_buffer.ptr = 1
    s.input_buffer.size = 0
    write(s.input_buffer, l)
    deactivate_region(s)
    nothing
end


edit_indent_left(s::MIState, n=1) = edit_indent(s, -n)
edit_indent_right(s::MIState, n=1) = edit_indent(s, n)

function edit_indent(s::MIState, num::Int)
    set_action!(s, :edit_indent)
    push_undo(s)
    if edit_indent(buffer(s), num, is_region_active(s))
        return refresh_line(s)
    else
        pop_undo(s)
        return :ignore
    end
end

# return the indices in buffer(s) of the beginning of each lines
# having a non-empty intersection with region(s)
function get_lines_in_region(s::BufferLike)
    buf = buffer(s)
    b, e = region(buf)
    bol = Int[beginofline(buf, b)] # begin of lines
    while true
        b = endofline(buf, b)
        b >= e && break
        # b < e ==> b+1 <= e <= buf.size
        push!(bol, b += 1)
    end
    return bol
end

# compute the number of spaces from b till the next non-space on the right
# (which can also be "end of line" or "end of buffer")
function leadingspaces(buf::IOBuffer, b::Int)
    @views ls = something(findnext(_notspace, buf.data[1:buf.size], b+1), 0)-1
    ls == -1 && (ls = buf.size)
    ls -= b
    return ls
end

# indent by abs(num) characters, on the right if num >= 0, on the left otherwise
# if multiline is true, indent all the lines in the region as a block.
function edit_indent(buf::IOBuffer, num::Int, multiline::Bool)
    bol = multiline ? get_lines_in_region(buf) : Int[beginofline(buf)]
    if num < 0
        # count leading spaces on the lines, which are an upper bound
        # on the number of spaces characters that can be removed
        ls_min = minimum(leadingspaces(buf, b) for b in bol)
        ls_min == 0 && return false # can't left-indent, no space can be removed
        num = -min(-num, ls_min)
    end
    for b in reverse!(bol) # reverse! to not mess-up the bol's offsets
        _edit_indent(buf, b, num)
    end
    return true
end

# indents line starting a position b by num positions
# if num < 0, it is assumed that there are at least num white spaces
# at the beginning of line
_edit_indent(buf::IOBuffer, b::Int, num::Int) =
    num >= 0 ? edit_splice!(buf, b => b, ' '^num, rigid_mark=false) :
               edit_splice!(buf, b => (b - num))

function mode_idx(hist::HistoryProvider, mode::TextInterface)
    c = :julia
    for (k,v) in hist.mode_mapping
        isequal(v, mode) && (c = k)
    end
    return c
end

function guess_current_mode_name(s)
    try
        mode_idx(s.current_mode.hist, s.current_mode)
    catch
        nothing
    end
end

# edit current input in editor
function edit_input(s, f = (filename, line, column) -> InteractiveUtils.edit(filename, line, column))
    mode_name = guess_current_mode_name(s)
    filename = tempname()
    if mode_name === :julia
        filename *= ".jl"
    elseif mode_name === :shell
        filename *= ".sh"
    end
    buf = buffer(s)
    pos = position(buf)
    str = takestring!(buf)
    lines = readlines(IOBuffer(str); keep=true)

    # Compute line
    line_start_offset = 0
    line = 1
    while line < length(lines) && line_start_offset + sizeof(lines[line]) <= pos
        line_start_offset += sizeof(lines[line])
        line += 1
    end

    # Compute column
    col = 0
    off = line_start_offset
    while off <= pos
        off = nextind(str, off)
        col += 1
    end

    # Write current input to temp file, edit, read back
    write(filename, str)
    f(filename, line, col)
    str_mod = readchomp(filename)
    rm(filename)

    # Write updated content
    write(buf, str_mod)
    if str == str_mod
        # If input was not modified: reset cursor
        seek(buf, pos)
    else
        # If input was modified: move cursor to end
        move_input_end(s)
    end
    refresh_line(s)
end

# return the identifier under the cursor, possibly with other words concatenated
# to it with dots (e.g. "A.B.C" in "X; A.B.C*3", if the cursor is between "A" and "C")
function current_word_with_dots(buf::IOBuffer)
    pos = position(buf)
    while true
        char_move_word_right(buf)
        if eof(buf) || peek(buf, Char) != '.'
            break
        end
    end
    pend = position(buf)
    while true
        char_move_word_left(buf)
        p = position(buf)
        p == 0 && break
        seek(buf, p-1)
        if peek(buf, Char) != '.'
            seek(buf, p)
            break
        end
    end
    pbegin = position(buf)
    word = pend > pbegin ?
        String(buf.data[pbegin+1:pend]) :
        ""
    seek(buf, pos)
    word
end

current_word_with_dots(s::MIState) = current_word_with_dots(buffer(s))

function activate_module(s::MIState)
    word = current_word_with_dots(s);
    empty = isempty(word)
    mod = if empty
        s.previous_active_module
    else
        try
            Base.Core.eval(Base.active_module(), Base.Meta.parse(word))
        catch
            nothing
        end
    end
    if !(mod isa Module) || mod == Base.active_module()
        beep(s)
        return
    end
    empty && edit_insert(s, ' ') # makes the `edit_clear` below actually update the prompt
    if Base.active_module() == Main || mod == Main
        # At least one needs to be Main. Disallows toggling between two non-Main modules because it's
        # otherwise hard to get back to Main
        s.previous_active_module = Base.active_module()
    end
    REPL.activate(mod)
    edit_clear(s)
end

history_prev(::EmptyHistoryProvider) = ("", false)
history_next(::EmptyHistoryProvider) = ("", false)
history_first(::EmptyHistoryProvider) = ("", false)
history_last(::EmptyHistoryProvider) = ("", false)
history_search(::EmptyHistoryProvider, args...) = false
add_history(::EmptyHistoryProvider, s) = nothing
add_history(s::PromptState) = add_history(mode(s).hist, s)
history_next_prefix(s, hist, prefix) = false
history_prev_prefix(s, hist, prefix) = false

function history_prev(s::ModeState, hist)
    l, ok = history_prev(mode(s).hist)
    if ok
        replace_line(s, l)
        move_input_start(s)
        refresh_line(s)
    else
        beep(s)
    end
    nothing
end
function history_next(s::ModeState, hist)
    l, ok = history_next(mode(s).hist)
    if ok
        replace_line(s, l)
        move_input_end(s)
        refresh_line(s)
    else
        beep(s)
    end
    nothing
end

refresh_line(s::BufferLike) = refresh_multi_line(s)
refresh_line(s::BufferLike, termbuf::AbstractTerminal) = refresh_multi_line(termbuf, s)

default_completion_cb(::IOBuffer) = []
default_enter_cb(_) = true

write_prompt(terminal::AbstractTerminal, s::PromptState, color::Bool) = write_prompt(terminal, s.p, color)
function write_prompt(terminal::AbstractTerminal, p::Prompt, color::Bool)
    prefix = prompt_string(p.prompt_prefix)
    suffix = prompt_string(p.prompt_suffix)
    write(terminal, prefix)
    color && write(terminal, Base.text_colors[:bold])
    width = write_prompt(terminal, p.prompt, color)
    color && write(terminal, Base.text_colors[:normal])
    write(terminal, suffix)
    return width
end

function write_output_prefix(io::IO, p::Prompt, color::Bool)
    prefix = prompt_string(p.output_prefix_prefix)
    suffix = prompt_string(p.output_prefix_suffix)
    print(io, prefix)
    color && write(io, Base.text_colors[:bold])
    width = write_prompt(io, p.output_prefix, color)
    color && write(io, Base.text_colors[:normal])
    print(io, suffix)
    return width
end

# On Windows, when launching external processes, we cannot control what assumption they make on the
# console mode. We thus forcibly reset the console mode at the start of the prompt to ensure they do
# not leave the console mode in a corrupt state.
# FIXME: remove when pseudo-tty are implemented for child processes
if Sys.iswindows()

#= Get/SetConsoleMode flags =#
const ENABLE_PROCESSED_OUTPUT            = UInt32(0x0001)
const ENABLE_WRAP_AT_EOL_OUTPUT          = UInt32(0x0002)
const ENABLE_VIRTUAL_TERMINAL_PROCESSING = UInt32(0x0004)
const DISABLE_NEWLINE_AUTO_RETURN        = UInt32(0x0008)
const ENABLE_LVB_GRID_WORLDWIDE          = UInt32(0x0010)

#= libuv flags =#
const UV_TTY_SUPPORTED = 0
const UV_TTY_UNSUPPORTED = 1

function _reset_console_mode(handle::Ptr{Cvoid})
    # Query libuv to see whether it expects the console to support virtual terminal sequences
    vterm_state = Ref{Cint}()
    ccall(:uv_tty_get_vterm_state, Cint, (Ref{Cint},), vterm_state)

    mode::UInt32 = ENABLE_PROCESSED_OUTPUT | ENABLE_WRAP_AT_EOL_OUTPUT
    if vterm_state[] == UV_TTY_SUPPORTED
        mode |= ENABLE_VIRTUAL_TERMINAL_PROCESSING
    end

    # Expected to fail (benignly) with ERROR_INVALID_HANDLE if the provided handle does not
    # allow setting the console mode
    ccall(:SetConsoleMode, stdcall, Int32, (Ptr{Cvoid}, UInt32), handle, mode)

    return nothing
end

end

# returns the width of the written prompt
function write_prompt(terminal::Union{IO, AbstractTerminal}, s::Union{AbstractString,Function}, color::Bool)
    promptstr = prompt_string(s)::String
    write(terminal, promptstr)
    return textwidth(promptstr)
end

### Keymap Support

const wildcard = '\U10f7ff' # "Private Use" Char

normalize_key(key::Char) = string(key)
normalize_key(key::Union{Int,UInt8}) = normalize_key(Char(key))
function normalize_key(key::Union{String,SubString{String}})
    wildcard in key && error("Matching '\U10f7ff' not supported.")
    buf = IOBuffer()
    i = firstindex(key)
    while i <= ncodeunits(key)
        c, i = iterate(key, i)
        if c == '*'
            write(buf, wildcard)
        elseif c == '^'
            c, i = iterate(key, i)
            write(buf, uppercase(c)-64)
        elseif c == '\\'
            c, i = iterate(key, i)
            if c == 'C'
                c, i = iterate(key, i)
                c == '-' || error("the Control key specifier must start with \"\\\\C-\"")
                c, i = iterate(key, i)
                write(buf, uppercase(c)-64)
            elseif c == 'M'
                c, i = iterate(key, i)
                c == '-' || error("the Meta key specifier must start with \"\\\\M-\"")
                c, i = iterate(key, i)
                write(buf, '\e')
                write(buf, c)
            end
        else
            write(buf, c)
        end
    end
    return takestring!(buf)
end

function normalize_keys(keymap::Union{Dict{Char,Any},AnyDict})
    ret = Dict{Any,Any}()
    for (k,v) in keymap
        normalized = normalize_key(k)
        if haskey(ret,normalized)
            error("""Multiple spellings of a key in a single keymap
                     (\"$k\" conflicts with existing mapping)""")
        end
        ret[normalized] = v
    end
    return ret
end

function add_nested_key!(keymap::Dict{Char, Any}, key::Union{String, Char}, value; override::Bool = false)
    y = iterate(key)
    while y !== nothing
        c, i = y
        y = iterate(key, i)
        if !override && c in keys(keymap) && (y === nothing || !isa(keymap[c], Dict))
            error("Conflicting definitions for keyseq " * escape_string(key) *
                  " within one keymap")
        end
        if y === nothing
            keymap[c] = value
            break
        elseif !(c in keys(keymap) && isa(keymap[c], Dict))
            keymap[c] = Dict{Char,Any}()
        end
        keymap = keymap[c]::Dict{Char, Any}
    end
end

# Redirect a key as if `seq` had been the keysequence instead in a lazy fashion.
# This is different from the default eager redirect, which only looks at the current and lower
# layers of the stack.
struct KeyAlias
    seq::String
    KeyAlias(seq) = new(normalize_key(seq))
end

function match_input(f::Function, s::Union{Nothing,MIState}, term, cs::Vector{Char}, keymap)
    update_key_repeats(s, cs)
    c = String(cs)
    return function (s, p)  # s::Union{Nothing,MIState}; p can be (at least) a LineEditREPL, PrefixSearchState, Nothing
        r = Base.invokelatest(f, s, p, c)
        if isa(r, Symbol)
            return r
        else
            return :ok
        end
    end
end

match_input(k::Nothing, s, term, cs, keymap) = (s,p) -> return :ok
match_input(k::KeyAlias, s::Union{Nothing,MIState}, term, cs, keymap::Dict{Char}) =
    match_input(keymap, s, IOBuffer(k.seq), Char[], keymap)

function match_input(k::Dict{Char}, s::Union{Nothing,MIState}, term::Union{AbstractTerminal,IOBuffer}=terminal(s), cs::Vector{Char}=Char[], keymap::Dict{Char} = k)
    # if we run out of characters to match before resolving an action,
    # return an empty keymap function
    eof(term) && return (s, p) -> :abort
    c = read(term, Char)
    # Ignore any `wildcard` as this is used as a
    # placeholder for the wildcard (see normalize_key("*"))
    c == wildcard && return (s, p) -> :ok
    push!(cs, c)
    key = haskey(k, c) ? c : wildcard
    # if we don't match on the key, look for a default action then fallback on 'nothing' to ignore
    return match_input(get(k, key, nothing), s, term, cs, keymap)
end

update_key_repeats(s, keystroke) = nothing
function update_key_repeats(s::MIState, keystroke::Vector{Char})
    s.key_repeats  = s.previous_key == keystroke ? s.key_repeats + 1 : 0
    s.previous_key = keystroke
    return
end


## Conflict fixing
# Consider a keymap of the form
#
# {
#   "**" => f
#   "ab" => g
# }
#
# Naively this is transformed into a tree as
#
# {
#   '*' => {
#       '*' => f
#   }
#   'a' => {
#       'b' => g
#   }
# }
#
# However, that's not what we want, because now "ac" is
# is not defined. We need to fix this up and turn it into
#
# {
#   '*' => {
#       '*' => f
#   }
#   'a' => {
#       '*' => f
#       'b' => g
#   }
# }
#
# i.e. copy over the appropriate default subdict
#

# deep merge where target has higher precedence
function keymap_merge!(target::Dict{Char,Any}, source::Union{Dict{Char,Any},AnyDict})
    for k in keys(source)
        if !haskey(target, k)
            target[k] = source[k]
        elseif isa(target[k], Dict)
            keymap_merge!(target[k], source[k])
        else
            # Ignore, target has higher precedence
        end
    end
end

fixup_keymaps!(d, l, s, sk) = nothing
function fixup_keymaps!(dict::Dict{Char,Any}, level, s, subkeymap)
    if level > 0
        for d in values(dict)
            fixup_keymaps!(d, level-1, s, subkeymap)
        end
    else
        if haskey(dict, s)
            if isa(dict[s], Dict) && isa(subkeymap, Dict)
                keymap_merge!(dict[s], subkeymap)
            end
        else
            dict[s] = deepcopy(subkeymap)
        end
    end
    nothing
end

function add_specialisations(dict::Dict{Char,Any}, subdict::Dict{Char,Any}, level::Int)
    default_branch = subdict[wildcard]
    if isa(default_branch, Dict)
        default_branch = default_branch::Dict{Char,Any}
        # Go through all the keymaps in the default branch
        # and copy them over to dict
        for s in keys(default_branch)
            s == wildcard && add_specialisations(dict, default_branch, level+1)
            fixup_keymaps!(dict, level, s, default_branch[s])
        end
    end
end

postprocess!(others) = nothing
function postprocess!(dict::Dict{Char,Any})
    # needs to be done first for every branch
    if haskey(dict, wildcard)
        add_specialisations(dict, dict, 1)
    end
    for (k,v) in dict
        k == wildcard && continue
        postprocess!(v)
    end
end

function getEntry(keymap::Dict{Char,Any},key::Union{String,Char})
    v = keymap
    for c in key
        if !(haskey(v,c)::Bool)
            return nothing
        end
        v = v[c]
    end
    return v
end

# `target` is the total keymap being built up, already being a nested tree of Dicts.
# source is the keymap specified by the user (with normalized keys)
function keymap_merge(target::Dict{Char,Any}, source::Union{Dict{Char,Any},AnyDict})
    ret = copy(target)
    direct_keys = filter(p -> isa(p.second, Union{Function, KeyAlias, Nothing}), source)
    # first direct entries
    for key in keys(direct_keys)
        add_nested_key!(ret, key, source[key]; override = true)
    end
    # then redirected entries
    for key in setdiff(keys(source), keys(direct_keys))
        key::Union{String, Char}
        # We first resolve redirects in the source
        value = source[key]
        visited = Vector{Any}()
        while isa(value, Union{Char,String})
            value = normalize_key(value)
            if value in visited
                throw_eager_redirection_cycle(key)
            end
            push!(visited,value)
            if !haskey(source,value)
                break
            end
            value = source[value]
        end

        if isa(value, Union{Char,String})
            value = getEntry(ret, value)
            if value === nothing
                throw_could_not_find_redirected_value(key)
            end
        end
        add_nested_key!(ret, key, value; override = true)
    end
    return ret
end

throw_eager_redirection_cycle(key::Union{Char, String}) =
    error("Eager redirection cycle detected for key ", repr(key))
throw_could_not_find_redirected_value(key::Union{Char, String}) =
    error("Could not find redirected value ", repr(key))

function keymap_unify(keymaps)
    ret = Dict{Char,Any}()
    for keymap in keymaps
        ret = keymap_merge(ret, keymap)
    end
    postprocess!(ret)
    return ret
end

function validate_keymap(keymap)
    for key in keys(keymap)
        visited_keys = Any[key]
        v = getEntry(keymap,key)
        while isa(v,KeyAlias)
            if v.seq in visited_keys
                error("Alias cycle detected in keymap")
            end
            push!(visited_keys,v.seq)
            v = getEntry(keymap,v.seq)
        end
    end
end

function keymap(keymaps::Union{Vector{AnyDict},Vector{Dict{Char,Any}}})
    # keymaps is a vector of prioritized keymaps, with highest priority first
    ret = keymap_unify(map(normalize_keys, reverse(keymaps)))
    validate_keymap(ret)
    return ret
end

const escape_defaults = merge!(
    AnyDict(Char(i) => nothing for i=vcat(0:26, 28:31)), # Ignore control characters by default
    AnyDict( # And ignore other escape sequences by default
        "\e*" => nothing,
        "\e[*" => nothing,
        "\eO*" => nothing,
        # Also ignore extended escape sequences
        # TODO: Support ranges of characters
        "\e[1**" => nothing,
        "\e[2**" => nothing,
        "\e[3**" => nothing,
        "\e[4**" => nothing,
        "\e[5**" => nothing,
        "\e[6**" => nothing,
        # less commonly used VT220 editing keys
        "\e[2~" => nothing, # insert
        "\e[3~" => nothing, # delete
        "\e[5~" => nothing, # page up
        "\e[6~" => nothing, # page down
        # These are different spellings of arrow keys, home keys, etc.
        # and should always do the same as the canonical key sequence
        "\e[1~" => KeyAlias("\e[H"), # home
        "\e[4~" => KeyAlias("\e[F"), # end
        "\e[7~" => KeyAlias("\e[H"), # home
        "\e[8~" => KeyAlias("\e[F"), # end
        "\eOA"  => KeyAlias("\e[A"),
        "\eOB"  => KeyAlias("\e[B"),
        "\eOC"  => KeyAlias("\e[C"),
        "\eOD"  => KeyAlias("\e[D"),
        "\eOH"  => KeyAlias("\e[H"),
        "\eOF"  => KeyAlias("\e[F"),
    ),
    # set mode commands
    AnyDict("\e[$(c)h" => nothing for c in 1:20),
    # reset mode commands
    AnyDict("\e[$(c)l" => nothing for c in 1:20)
    )

mutable struct HistoryPrompt <: TextInterface
    hp::HistoryProvider
    complete::CompletionProvider
    keymap_dict::Dict{Char,Any}
    HistoryPrompt(hp) = new(hp, EmptyCompletionProvider())
end

mutable struct SearchState <: ModeState
    terminal::AbstractTerminal
    histprompt::HistoryPrompt
    #rsearch (true) or ssearch (false)
    backward::Bool
    query_buffer::IOBuffer
    response_buffer::IOBuffer
    failed::Bool
    ias::InputAreaState
    #The prompt whose input will be replaced by the matched history
    parent::Prompt
    SearchState(terminal, histprompt, backward, query_buffer, response_buffer) =
        new(terminal, histprompt, backward, query_buffer, response_buffer, false, InputAreaState(0,0))
end

init_state(terminal, p::HistoryPrompt) = SearchState(terminal, p, true, IOBuffer(), IOBuffer())

terminal(s::SearchState) = s.terminal

function update_display_buffer(s::SearchState, data::ModeState)
    s.failed = !history_search(data.histprompt.hp, data.query_buffer, data.response_buffer, data.backward, false)
    s.failed && beep(s)
    refresh_line(s)
    nothing
end

function history_next_result(s::MIState, data::ModeState)
    data.failed = !history_search(data.histprompt.hp, data.query_buffer, data.response_buffer, data.backward, true)
    data.failed && beep(s)
    refresh_line(data)
    nothing
end

function history_set_backward(s::SearchState, backward::Bool)
    s.backward = backward
    nothing
end

input_string(s::SearchState) = takestring!(copy(s.query_buffer))

function reset_state(s::SearchState)
    if s.query_buffer.size != 0
        s.query_buffer.size = 0
        s.query_buffer.ptr = 1
    end
    if s.response_buffer.size != 0
        s.response_buffer.size = 0
        s.response_buffer.ptr = 1
    end
    reset_state(s.histprompt.hp)
    s.failed = false
    nothing
end

# a meta-prompt that presents itself as parent_prompt, but which has an independent keymap
# for prefix searching
mutable struct PrefixHistoryPrompt <: TextInterface
    hp::HistoryProvider
    parent_prompt::Prompt
    complete::CompletionProvider
    keymap_dict::Dict{Char,Any}
    PrefixHistoryPrompt(hp, parent_prompt) =
        new(hp, parent_prompt, EmptyCompletionProvider())
end

mutable struct PrefixSearchState <: ModeState
    terminal::AbstractTerminal
    histprompt::PrefixHistoryPrompt
    prefix::String
    response_buffer::IOBuffer
    ias::InputAreaState
    indent::Int
    # The modal interface state, if present
    mi::MIState
    #The prompt whose input will be replaced by the matched history
    parent::Prompt
    PrefixSearchState(terminal, histprompt, prefix, response_buffer) =
        new(terminal, histprompt, prefix, response_buffer, InputAreaState(0,0), 0)
end

# interface for ModeState
function Base.getproperty(s::ModeState, name::Symbol)
    if name === :terminal
        return getfield(s, :terminal)::AbstractTerminal
    elseif name === :prompt
        return getfield(s, :prompt)::Prompt
    elseif name === :histprompt
        return getfield(s, :histprompt)::Union{HistoryPrompt,PrefixHistoryPrompt}
    elseif name === :parent
        return getfield(s, :parent)::Prompt
    elseif name === :response_buffer
        return getfield(s, :response_buffer)::IOBuffer
    elseif name === :ias
        return getfield(s, :ias)::InputAreaState
    elseif name === :indent
        return getfield(s, :indent)::Int
    # # unique fields, but no harm in declaring them
    # elseif name === :input_buffer
    #     return getfield(s, :input_buffer)::IOBuffer
    # elseif name === :region_active
    #     return getfield(s, :region_active)::Symbol
    # elseif name === :undo_buffers
    #     return getfield(s, :undo_buffers)::Vector{IOBuffer}
    # elseif name === :undo_idx
    end
    return getfield(s, name)
end

init_state(terminal, p::PrefixHistoryPrompt) = PrefixSearchState(terminal, p, "", IOBuffer())

function show(io::IO, s::PrefixSearchState)
    print(io, "PrefixSearchState ", isdefined(s,:parent) ?
     string("(", s.parent, " active)") : "(no parent)", " for ",
     isdefined(s,:mi) ? s.mi : "no MI")
end

function refresh_multi_line(termbuf::TerminalBuffer, terminal::UnixTerminal,
                            s::Union{PromptState,PrefixSearchState}; beeping::Bool=false)
    beeping || cancel_beep(s)
    ias = refresh_multi_line(termbuf, terminal, buffer(s), s.ias, s;
                             indent = s.indent,
                             region_active = is_region_active(s))
    s.ias = ias
    return ias
end

input_string(s::PrefixSearchState) = takestring!(copy(s.response_buffer))

write_prompt(terminal, s::PrefixSearchState, color::Bool) = write_prompt(terminal, s.histprompt.parent_prompt, color)
prompt_string(s::PrefixSearchState) = prompt_string(s.histprompt.parent_prompt.prompt)

terminal(s::PrefixSearchState) = s.terminal

function reset_state(s::PrefixSearchState)
    if s.response_buffer.size != 0
        s.response_buffer.size = 0
        s.response_buffer.ptr = 1
    end
    reset_state(s.histprompt.hp)
    nothing
end

function transition(f::Function, s::PrefixSearchState, mode::Prompt)
    if isdefined(s, :mi)
        transition(s.mi, mode)
    end
    s.parent = mode
    s.histprompt.parent_prompt = mode
    if isdefined(s, :mi)
        transition(f, s.mi, s.histprompt)
    else
        f()
    end
    nothing
end

replace_line(s::PrefixSearchState, l::IOBuffer) = (s.response_buffer = l; nothing)
function replace_line(s::PrefixSearchState, l::Union{String,SubString{String}})
    s.response_buffer.ptr = 1
    s.response_buffer.size = 0
    write(s.response_buffer, l)
    nothing
end

function refresh_multi_line(termbuf::TerminalBuffer, s::SearchState)
    buf = IOBuffer()
    unsafe_write(buf, pointer(s.query_buffer.data), s.query_buffer.ptr-1)
    write(buf, "': ")
    offset = buf.ptr
    ptr = s.response_buffer.ptr
    seek(s.response_buffer, 0)
    write(buf, read(s.response_buffer, String))
    buf.ptr = offset + ptr - 1
    s.response_buffer.ptr = ptr
    failed = s.failed ? "failed " : ""
    ias = refresh_multi_line(termbuf, s.terminal, buf, s.ias,
                             s.backward ? "($(failed)reverse-i-search)`" : "($(failed)forward-i-search)`")
    s.ias = ias
    return ias
end

state(s::MIState, p::TextInterface=mode(s)) = s.mode_state[p]
state(s::PromptState, p::Prompt=mode(s)) = (@assert s.p == p; s)

mode(s::MIState) = s.current_mode   # ::TextInterface, and might be a Prompt
mode(s::PromptState) = s.p          # ::Prompt
mode(s::SearchState) = @assert false
mode(s::PrefixSearchState) = s.histprompt.parent_prompt   # ::Prompt

setmodifiers!(s::MIState, m::Modifiers) = setmodifiers!(mode(s), m)
setmodifiers!(p::Prompt, m::Modifiers) = setmodifiers!(p.complete, m)
setmodifiers!(c) = nothing

# Search Mode completions
function complete_line(s::SearchState, repeats, mod::Module; hint::Bool=false)
    completions, reg, should_complete = complete_line(s.histprompt.complete, s, mod; hint)
    # For now only allow exact completions in search mode
    if length(completions) == 1
        prev_pos = position(s)
        push_undo(s)
        edit_splice!(s, (prev_pos - reg.second - reg.first) => prev_pos, completions[1].completion)
        return true
    end
    return false
end

accept_result_newmode(hp::HistoryProvider) = nothing
function accept_result(s::MIState, p::TextInterface)
    parent = something(accept_result_newmode(p.hp), state(s, p).parent)
    transition(s, parent) do
        replace_line(state(s, parent), state(s, p).response_buffer)
        nothing
    end
    nothing
end

function copybuf!(dst::IOBuffer, src::IOBuffer)
    n = src.size
    ensureroom(dst, n)
    copyto!(dst.data, 1, src.data, 1, n)
    dst.size = src.size
    dst.ptr = src.ptr
    nothing
end

function enter_search(s::MIState, p::HistoryPrompt, backward::Bool)
    # a bit of hack to help fix #6325
    buf = copy(buffer(s))
    parent = mode(s)
    p.hp.last_mode = mode(s)
    p.hp.last_buffer = buf

    transition(s, p) do
        ss = state(s, p)
        ss.parent = parent
        ss.backward = backward
        truncate(ss.query_buffer, 0)
        ss.failed = false
        copybuf!(ss.response_buffer, buf)
    end
    nothing
end

function enter_prefix_search(s::MIState, p::PrefixHistoryPrompt, backward::Bool)
    buf = copy(buffer(s))
    parent = mode(s)

    transition(s, p) do
        local pss = state(s, p)
        pss.parent = parent
        pss.histprompt.parent_prompt = parent
        pss.prefix = String(buf.data[1:position(buf)])
        copybuf!(pss.response_buffer, buf)
        pss.indent = state(s, parent).indent
        pss.mi = s
    end
    pss = state(s, p)
    if backward
        history_prev_prefix(pss, pss.histprompt.hp, pss.prefix)
    else
        history_next_prefix(pss, pss.histprompt.hp, pss.prefix)
    end
    nothing
end

function setup_search_keymap(hp)
    p = HistoryPrompt(hp)
    pkeymap = AnyDict(
        "^R"      => (s::MIState,data::ModeState,c)->(history_set_backward(data, true); history_next_result(s, data)),
        "^S"      => (s::MIState,data::ModeState,c)->(history_set_backward(data, false); history_next_result(s, data)),
        '\r'      => (s::MIState,o...)->accept_result(s, p),
        '\n'      => '\r',
        # Limited form of tab completions
        '\t'      => (s::MIState,data::ModeState,c)->(complete_line(s); update_display_buffer(s, data)),
        "^L"      => (s::MIState,data::ModeState,c)->(Terminals.clear(terminal(s)); update_display_buffer(s, data)),

        # Backspace/^H
        '\b'      => (s::MIState,data::ModeState,c)->(edit_backspace(data.query_buffer) ?
                        update_display_buffer(s, data) : beep(s)),
        127       => KeyAlias('\b'),
        # Meta Backspace
        "\e\b"    => (s::MIState,data::ModeState,c)->(isempty(edit_delete_prev_word(data.query_buffer)) ?
                                  beep(s) : update_display_buffer(s, data)),
        "\e\x7f"  => "\e\b",
        # Word erase to whitespace
        "^W"      => (s::MIState,data::ModeState,c)->(isempty(edit_werase(data.query_buffer)) ?
                                  beep(s) : update_display_buffer(s, data)),
        # ^C and ^D
        "^C"      => (s::MIState,data::ModeState,c)->(edit_clear(data.query_buffer);
                       edit_clear(data.response_buffer);
                       update_display_buffer(s, data);
                       reset_state(data.histprompt.hp);
                       transition(s, data.parent)),
        "^D"      => "^C",
        # Other ways to cancel search mode (it's difficult to bind \e itself)
        "^G"      => "^C",
        "\e\e"    => "^C",
        "^K"      => (s::MIState,o...)->transition(s, state(s, p).parent),
        "^Y"      => (s::MIState,data::ModeState,c)->(edit_yank(s); update_display_buffer(s, data)),
        "^U"      => (s::MIState,data::ModeState,c)->(edit_clear(data.query_buffer);
                     edit_clear(data.response_buffer);
                     update_display_buffer(s, data)),
        # Right Arrow
        "\e[C"    => (s::MIState,o...)->(accept_result(s, p); edit_move_right(s)),
        # Left Arrow
        "\e[D"    => (s::MIState,o...)->(accept_result(s, p); edit_move_left(s)),
        # Up Arrow
        "\e[A"    => (s::MIState,o...)->(accept_result(s, p); edit_move_up(s)),
        # Down Arrow
        "\e[B"    => (s::MIState,o...)->(accept_result(s, p); edit_move_down(s)),
        "^B"      => (s::MIState,o...)->(accept_result(s, p); edit_move_left(s)),
        "^F"      => (s::MIState,o...)->(accept_result(s, p); edit_move_right(s)),
        # Meta B
        "\eb"     => (s::MIState,o...)->(accept_result(s, p); edit_move_word_left(s)),
        # Meta F
        "\ef"     => (s::MIState,o...)->(accept_result(s, p); edit_move_word_right(s)),
        # Ctrl-Left Arrow
        "\e[1;5D" => "\eb",
        # Ctrl-Left Arrow on rxvt
        "\eOd" => "\eb",
        # Ctrl-Right Arrow
        "\e[1;5C" => "\ef",
        # Ctrl-Right Arrow on rxvt
        "\eOc" => "\ef",
        "^A"         => (s::MIState,o...)->(accept_result(s, p); move_line_start(s); refresh_line(s)),
        "^E"         => (s::MIState,o...)->(accept_result(s, p); move_line_end(s); refresh_line(s)),
        "^Z"      => (s::MIState,o...)->(return :suspend),
        # Try to catch all Home/End keys
        "\e[H"    => (s::MIState,o...)->(accept_result(s, p); move_input_start(s); refresh_line(s)),
        "\e[F"    => (s::MIState,o...)->(accept_result(s, p); move_input_end(s); refresh_line(s)),
        # Use ^N and ^P to change search directions and iterate through results
        "^N"      => (s::MIState,data::ModeState,c)->(history_set_backward(data, false); history_next_result(s, data)),
        "^P"      => (s::MIState,data::ModeState,c)->(history_set_backward(data, true); history_next_result(s, data)),
        # Bracketed paste mode
        "\e[200~" => (s::MIState,data::ModeState,c)-> begin
            ps = state(s, mode(s))
            input = readuntil(ps.terminal, "\e[201~", keep=false)
            edit_insert(data.query_buffer, input); update_display_buffer(s, data)
        end,
        "*"       => (s::MIState,data::ModeState,c::StringLike)->(edit_insert(data.query_buffer, c); update_display_buffer(s, data))
    )
    p.keymap_dict = keymap([pkeymap, escape_defaults])
    skeymap = AnyDict(
        "^R"    => (s::MIState,o...)->(enter_search(s, p, true)),
        "^S"    => (s::MIState,o...)->(enter_search(s, p, false)),
    )
    return (p, skeymap)
end

keymap(state, p::Union{HistoryPrompt,PrefixHistoryPrompt}) = p.keymap_dict
keymap_data(state, ::Union{HistoryPrompt, PrefixHistoryPrompt}) = state

Base.isempty(s::PromptState) = s.input_buffer.size == 0

on_enter(s::MIState) = state(s).p.on_enter(s)

move_input_start(s::BufferLike) = (seek(buffer(s), 0); nothing)
move_input_end(buf::IOBuffer) = (seekend(buf); nothing)
move_input_end(s::Union{MIState,ModeState}) = (move_input_end(buffer(s)); nothing)

function move_line_start(s::MIState)
    set_action!(s, :move_line_start)
    buf = buffer(s)
    curpos = position(buf)
    curpos == 0 && return
    if s.key_repeats > 0
        move_input_start(s)
    else
        seek(buf, something(findprev(isequal(UInt8('\n')), buf.data, curpos), 0))
    end
    nothing
end

function move_line_end(s::MIState)
    set_action!(s, :move_line_end)
    s.key_repeats > 0 ?
        move_input_end(s) :
        move_line_end(buffer(s))
    nothing
end

function move_line_end(buf::IOBuffer)
    eof(buf) && return
    @views pos = findnext(isequal(UInt8('\n')), buf.data[1:buf.size], position(buf)+1)
    if pos === nothing
        move_input_end(buf)
        return
    end
    seek(buf, pos - 1)
    nothing
end

edit_insert_last_word(s::MIState) =
    edit_insert(s, get_last_word(IOBuffer(mode(s).hist.history[end])))

function get_last_word(buf::IOBuffer)
    move_line_end(buf)
    char_move_word_left(buf)
    posbeg = position(buf)
    char_move_word_right(buf)
    posend = position(buf)
    buf = take!(buf)
    word = String(buf[posbeg+1:posend])
    rest = String(buf[posend+1:end])
    lp, rp, lb, rb = count.(.==(('(', ')', '[', ']')), rest)
    special = any(in.(('\'', '"', '`'), rest))
    !special && lp == rp && lb == rb ?
        word *= rest :
        word
end

function commit_line(s::MIState)
    cancel_beep(s)
    move_input_end(s)
    refresh_line(s)
    println(terminal(s))
    add_history(s)
    ias = InputAreaState(0, 0)
    state(s, mode(s)).ias = ias
    nothing
end

function bracketed_paste(s::MIState; tabwidth::Int=options(s).tabwidth)
    options(s).auto_indent_bracketed_paste = true
    ps = state(s, mode(s))::PromptState
    input = readuntil(ps.terminal, "\e[201~")
    input = replace(input, '\r' => '\n')
    if position(buffer(s)) == 0
        indent = Base.indentation(input; tabwidth=tabwidth)[1]
        input = Base.unindent(input, indent; tabwidth=tabwidth)
    end
    return replace(input, '\t' => " "^tabwidth)
end

function tab_should_complete(s::MIState)
    # Yes, we are ignoring the possibility
    # the we could be in the middle of a multi-byte
    # sequence, here but that's ok, since any
    # whitespace we're interested in is only one byte
    buf = buffer(s)
    pos = position(buf)
    pos == 0 && return true
    c = buf.data[pos]
    return c != _newline && c != UInt8('\t') &&
        # hack to allow path completion in cmds
        # after a space, e.g., `cd <tab>`, while still
        # allowing multiple indent levels
        (c != _space || pos <= 3 || buf.data[pos-1] != _space)
end

# jump_spaces: if cursor is on a ' ', move it to the first non-' ' char on the right
# if `delete_trailing`, ignore trailing ' ' by deleting them
function edit_tab(s::MIState, jump_spaces::Bool=false, delete_trailing::Bool=jump_spaces)
    tab_should_complete(s) && return complete_line(s)
    set_action!(s, :edit_insert_tab)
    push_undo(s)
    edit_insert_tab(buffer(s), jump_spaces, delete_trailing) || pop_undo(s)
    return refresh_line(s)
end

function shift_tab_completion(s::MIState)
    setmodifiers!(s, Modifiers(true))
    return complete_line(s)
end

# return true iff the content of the buffer is modified
# return false when only the position changed
function edit_insert_tab(buf::IOBuffer, jump_spaces::Bool=false, delete_trailing::Bool=jump_spaces)
    i = position(buf)
    if jump_spaces && i < buf.size && buf.data[i+1] == _space
        spaces = something(findnext(_notspace, buf.data[i+1:buf.size], 1), 0)
        if delete_trailing && (spaces == 0 || buf.data[i+spaces] == _newline)
            edit_splice!(buf, i => (spaces == 0 ? buf.size : i+spaces-1))
        else
            jump = spaces == 0 ? buf.size : i+spaces-1
            seek(buf, jump)
            return false
        end
    end
    # align to multiples of 4:
    align = 4 - textwidth(String(buf.data[1+beginofline(buf, i):i])) % 4
    edit_insert(buf, ' '^align)
    return true
end

function edit_abort(s::MIState, confirm::Bool=options(s).confirm_exit; key="^D")
    set_action!(s, :edit_abort)
    if !confirm || s.last_action === :edit_abort
        println(terminal(s))
        return :abort
    else
        println("Type $key again to exit.\n")
        return refresh_line(s)
    end
end

const default_keymap =
AnyDict(
    # Tab
    '\t' => (s::MIState,o...)->edit_tab(s, true),
    # Shift-tab
    "\e[Z" => (s::MIState,o...)->shift_tab_completion(s),
    # Enter
    '\r' => (s::MIState,o...)->begin
        if on_enter(s) || (eof(buffer(s)) && s.key_repeats > 1)
            commit_line(s)
            return :done
        else
            edit_insert_newline(s)
        end
    end,
    '\n' => KeyAlias('\r'),
    # Backspace/^H
    '\b' => (s::MIState,o...) -> is_region_active(s) ? edit_kill_region(s) : edit_backspace(s),
    127 => KeyAlias('\b'),
    # Meta Backspace
    "\e\b" => (s::MIState,o...)->edit_delete_prev_word(s),
    "\e\x7f" => "\e\b",
    # ^D
    "^D" => (s::MIState,o...)->begin
        if buffer(s).size > 0
            edit_delete(s)
        else
            edit_abort(s)
        end
    end,
    # Ctrl-Space
    "\0" => (s::MIState,o...)->setmark(s),
    "^G" => (s::MIState,o...)->(deactivate_region(s); refresh_line(s)),
    "^X^X" => (s::MIState,o...)->edit_exchange_point_and_mark(s),
    "^B" => (s::MIState,o...)->edit_move_left(s),
    "^F" => (s::MIState,o...)->edit_move_right(s),
    "^P" => (s::MIState,o...)->edit_move_up(s),
    "^N" => (s::MIState,o...)->edit_move_down(s),
    # Meta-Up
    "\e[1;3A" => (s::MIState,o...) -> edit_transpose_lines_up!(s),
    # Meta-Down
    "\e[1;3B" => (s::MIState,o...) -> edit_transpose_lines_down!(s),
    "\e[1;2D" => (s::MIState,o...)->edit_shift_move(s, edit_move_left),
    "\e[1;2C" => (s::MIState,o...)->edit_shift_move(s, edit_move_right),
    "\e[1;2A" => (s::MIState,o...)->edit_shift_move(s, edit_move_up),
    "\e[1;2B" => (s::MIState,o...)->edit_shift_move(s, edit_move_down),
    # Meta B
    "\eb" => (s::MIState,o...)->edit_move_word_left(s),
    # Meta F
    "\ef" => (s::MIState,o...)->edit_move_word_right(s),
    # Ctrl-Left Arrow
    "\e[1;5D" => "\eb",
    # Ctrl-Left Arrow on rxvt
    "\eOd" => "\eb",
    # Ctrl-Right Arrow
    "\e[1;5C" => "\ef",
    # Ctrl-Right Arrow on rxvt
    "\eOc" => "\ef",
    # Meta Enter
    "\e\r" => (s::MIState,o...)->edit_insert_newline(s),
    "\e." =>  (s::MIState,o...)->edit_insert_last_word(s),
    "\e\n" => "\e\r",
    "^_" => (s::MIState,o...)->edit_undo!(s),
    "\e_" => (s::MIState,o...)->edit_redo!(s),
    # Show hints at what tab complete would do by default
    "*" => (s::MIState,data,c::StringLike)->(edit_insert(s, c); check_show_hint(s)),
    "^U" => (s::MIState,o...)->edit_kill_line_backwards(s),
    "^K" => (s::MIState,o...)->edit_kill_line_forwards(s),
    "^Y" => (s::MIState,o...)->edit_yank(s),
    "\ey" => (s::MIState,o...)->edit_yank_pop(s),
    "\ew" => (s::MIState,o...)->edit_copy_region(s),
    "\eW" => (s::MIState,o...)->edit_kill_region(s),
    "^A" => (s::MIState,o...)->(move_line_start(s); refresh_line(s)),
    "^E" => (s::MIState,o...)->(move_line_end(s); refresh_line(s)),
    # Try to catch all Home/End keys
    "\e[H"  => (s::MIState,o...)->(move_input_start(s); refresh_line(s)),
    "\e[F"  => (s::MIState,o...)->(move_input_end(s); refresh_line(s)),
    "^L" => (s::MIState,o...)->(Terminals.clear(terminal(s)); refresh_line(s)),
    "^W" => (s::MIState,o...)->edit_werase(s),
    # Meta D
    "\ed" => (s::MIState,o...)->edit_delete_next_word(s),
    "^C" => (s::MIState,o...)->begin
        try # raise the debugger if present
            ccall(:jl_raise_debugger, Int, ())
        catch
        end
        cancel_beep(s)
        move_input_end(s)
        refresh_line(s)
        print(terminal(s), "^C\n\n")
        transition(s, :reset)
        refresh_line(s)
    end,
    "^Z" => (s::MIState,o...)->(return :suspend),
    # Right Arrow
    "\e[C" => (s::MIState,o...)->edit_move_right(s),
    # Left Arrow
    "\e[D" => (s::MIState,o...)->edit_move_left(s),
    # Up Arrow
    "\e[A" => (s::MIState,o...)->edit_move_up(s),
    # Down Arrow
    "\e[B" => (s::MIState,o...)->edit_move_down(s),
    # Meta-Right Arrow
    "\e[1;3C" => (s::MIState,o...) -> edit_indent_right(s, 1),
    # Meta-Left Arrow
    "\e[1;3D" => (s::MIState,o...) -> edit_indent_left(s, 1),
    # Delete
    "\e[3~" => (s::MIState,o...)->edit_delete(s),
    # Bracketed Paste Mode
    "\e[200~" => (s::MIState,o...)->begin
        input = bracketed_paste(s)
        edit_insert(s, input)
    end,
    "^T" => (s::MIState,o...)->edit_transpose_chars(s),
    "\et" => (s::MIState,o...)->edit_transpose_words(s),
    "\eu" => (s::MIState,o...)->edit_upper_case(s),
    "\el" => (s::MIState,o...)->edit_lower_case(s),
    "\ec" => (s::MIState,o...)->edit_title_case(s),
    "\ee" => (s::MIState,o...) -> edit_input(s),
    "\em" => (s::MIState, o...) -> activate_module(s)
)

const history_keymap = AnyDict(
    "^P" => (s::MIState,o...)->(edit_move_up(s) || history_prev(s, mode(s).hist)),
    "^N" => (s::MIState,o...)->(edit_move_down(s) || history_next(s, mode(s).hist)),
    "\ep" => (s::MIState,o...)->(history_prev(s, mode(s).hist)),
    "\en" => (s::MIState,o...)->(history_next(s, mode(s).hist)),
    # Up Arrow
    "\e[A" => (s::MIState,o...)->(edit_move_up(s) || history_prev(s, mode(s).hist)),
    # Down Arrow
    "\e[B" => (s::MIState,o...)->(edit_move_down(s) || history_next(s, mode(s).hist)),
    # Page Up
    "\e[5~" => (s::MIState,o...)->(history_prev(s, mode(s).hist)),
    # Page Down
    "\e[6~" => (s::MIState,o...)->(history_next(s, mode(s).hist)),
    "\e<" => (s::MIState,o...)->(history_first(s, mode(s).hist)),
    "\e>" => (s::MIState,o...)->(history_last(s, mode(s).hist)),
)

const prefix_history_keymap = merge!(
    AnyDict(
        "^P" => (s::MIState,data::ModeState,c)->history_prev_prefix(data, data.histprompt.hp, data.prefix),
        "^N" => (s::MIState,data::ModeState,c)->history_next_prefix(data, data.histprompt.hp, data.prefix),
        # Up Arrow
        "\e[A" => (s::MIState,data::ModeState,c)->history_prev_prefix(data, data.histprompt.hp, data.prefix),
        # Down Arrow
        "\e[B" => (s::MIState,data::ModeState,c)->history_next_prefix(data, data.histprompt.hp, data.prefix),
        # by default, pass through to the parent mode
        "*"    => (s::MIState,data::ModeState,c::StringLike)->begin
            accept_result(s, data.histprompt);
            ps = state(s, mode(s))
            map = keymap(ps, mode(s))
            match_input(map, s, IOBuffer(c))(s, keymap_data(ps, mode(s)))
        end,
        # match escape sequences for pass through
        "^x*" => "*",
        "\em*" => "*",
        "\e*" => "*",
        "\e[*" => "*",
        "\eO*"  => "*",
        "\e[1;5*" => "*", # Ctrl-Arrow
        "\e[1;2*" => "*", # Shift-Arrow
        "\e[1;3*" => "*", # Meta-Arrow
        "\e[200~" => "*"
    ),
    # VT220 editing commands
    AnyDict("\e[$(n)~" => "*" for n in 1:8),
    # set mode commands
    AnyDict("\e[$(c)h" => "*" for c in 1:20),
    # reset mode commands
    AnyDict("\e[$(c)l" => "*" for c in 1:20)
)

function setup_prefix_keymap(hp::HistoryProvider, parent_prompt::Prompt)
    p = PrefixHistoryPrompt(hp, parent_prompt)
    p.keymap_dict = keymap([prefix_history_keymap])
    pkeymap = AnyDict(
        "^P" => (s::MIState,o...)->(edit_move_up(s) || enter_prefix_search(s, p, true)),
        "^N" => (s::MIState,o...)->(edit_move_down(s) || enter_prefix_search(s, p, false)),
        # Up Arrow
        "\e[A" => (s::MIState,o...)->(edit_move_up(s) || enter_prefix_search(s, p, true)),
        # Down Arrow
        "\e[B" => (s::MIState,o...)->(edit_move_down(s) || enter_prefix_search(s, p, false)),
    )
    return (p, pkeymap)
end

function deactivate(p::TextInterface, s::ModeState, termbuf::AbstractTerminal, term::TextTerminal)
    clear_input_area(termbuf, s)
    return s
end

function activate(p::TextInterface, s::ModeState, termbuf::AbstractTerminal, term::TextTerminal)
    s.ias = InputAreaState(0, 0)
    refresh_line(s, termbuf)
    nothing
end

function activate(p::TextInterface, s::MIState, termbuf::AbstractTerminal, term::TextTerminal)
    @assert p == mode(s)
    activate(p, state(s), termbuf, term)
    nothing
end
activate(m::ModalInterface, s::MIState, termbuf::AbstractTerminal, term::TextTerminal) =
    activate(mode(s), s, termbuf, term)

commit_changes(t::UnixTerminal, termbuf::TerminalBuffer) = (write(t, take!(termbuf.out_stream)); nothing)

function transition(f::Function, s::MIState, newmode::Union{TextInterface,Symbol})
    cancel_beep(s)
    if newmode === :abort
        s.aborted = true
        return
    end
    if newmode === :reset
        reset_state(s)
        return
    end
    if !haskey(s.mode_state, newmode)
        s.mode_state[newmode] = init_state(terminal(s), newmode)
    end
    termbuf = TerminalBuffer(IOBuffer())
    t = terminal(s)
    s.mode_state[mode(s)] = deactivate(mode(s), state(s), termbuf, t)
    s.current_mode = newmode
    f()
    activate(newmode, state(s, newmode), termbuf, t)
    commit_changes(t, termbuf)
    nothing
end
transition(s::MIState, mode::Union{TextInterface,Symbol}) = transition((args...)->nothing, s, mode)

function reset_state(s::PromptState)
    if s.input_buffer.size != 0
        s.input_buffer.size = 0
        s.input_buffer.ptr = 1
    end
    empty_undo(s)
    deactivate_region(s)
    ias = InputAreaState(0, 0)
    s.ias = ias
    return ias
end

function reset_state(s::MIState)
    for (mode, state) in s.mode_state
        reset_state(state)
    end
end

const default_keymap_dict = keymap([default_keymap, escape_defaults])

function Prompt(prompt
    ;
    prompt_prefix = "",
    prompt_suffix = "",
    output_prefix = "",
    output_prefix_prefix = "",
    output_prefix_suffix = "",
    keymap_dict = default_keymap_dict,
    repl = nothing,
    complete = EmptyCompletionProvider(),
    on_enter = default_enter_cb,
    on_done = ()->nothing,
    hist = EmptyHistoryProvider(),
    sticky = false)

    return Prompt(prompt, prompt_prefix, prompt_suffix, output_prefix, output_prefix_prefix, output_prefix_suffix,
                   keymap_dict, repl, complete, on_enter, on_done, hist, sticky)
end

run_interface(::Prompt) = nothing

init_state(terminal, prompt::Prompt) =
    PromptState(terminal, prompt, IOBuffer(), :off, nothing, IOBuffer[], 1, InputAreaState(1, 1),
                #=indent(spaces)=# -1, Threads.SpinLock(), 0.0, -Inf, nothing)

function init_state(terminal, m::ModalInterface)
    s = MIState(m, Main, m.modes[1], false, IdDict{Any,Any}())
    for mode in m.modes
        s.mode_state[mode] = init_state(terminal, mode)
    end
    return s
end


function run_interface(terminal::TextTerminal, m::ModalInterface, s::MIState=init_state(terminal, m))
    while !s.aborted
        buf, ok, suspend = prompt!(terminal, m, s)
        while suspend
            @static if Sys.isunix(); ccall(:jl_repl_raise_sigtstp, Cint, ()); end
            buf, ok, suspend = prompt!(terminal, m, s)
        end
        Base.invokelatest(mode(state(s)).on_done, s, buf, ok)
    end
end

buffer(s) = _buffer(s)::IOBuffer
_buffer(s::PromptState) = s.input_buffer
_buffer(s::SearchState) = s.query_buffer
_buffer(s::PrefixSearchState) = s.response_buffer
_buffer(s::IOBuffer) = s

position(s::Union{MIState,ModeState}) = position(buffer(s))

function empty_undo(s::PromptState)
    empty!(s.undo_buffers)
    s.undo_idx = 1
    nothing
end

empty_undo(s) = nothing

function push_undo(s::PromptState, advance::Bool=true)
    resize!(s.undo_buffers, s.undo_idx)
    s.undo_buffers[end] = copy(s.input_buffer)
    advance && (s.undo_idx += 1)
    nothing
end

push_undo(s) = nothing

# must be called after a push_undo
function pop_undo(s::PromptState)
    pop!(s.undo_buffers)
    s.undo_idx -= 1
    nothing
end

function edit_undo!(s::MIState)
    set_action!(s, :edit_undo!)
    s.last_action ∉ (:edit_redo!, :edit_undo!) && push_undo(s, false)
    if !edit_undo!(state(s))
        beep(s)
        return :ignore
    end
    return nothing
end

function edit_undo!(s::PromptState)
    s.undo_idx > 1 || return false
    s.input_buffer = s.undo_buffers[s.undo_idx -=1]
    refresh_line(s)
    return true
end
edit_undo!(s) = nothing

function edit_redo!(s::MIState)
    set_action!(s, :edit_redo!)
    if s.last_action ∉ (:edit_redo!, :edit_undo!) || !edit_redo!(state(s))
        beep(s)
        return :ignore
    end
    return nothing
end

function edit_redo!(s::PromptState)
    s.undo_idx < length(s.undo_buffers) || return false
    s.input_buffer = s.undo_buffers[s.undo_idx += 1]
    refresh_line(s)
    return true
end
edit_redo!(s) = nothing

keymap(s::PromptState, prompt::Prompt) = prompt.keymap_dict
keymap_data(s::PromptState, prompt::Prompt) = prompt.repl
keymap(ms::MIState, m::ModalInterface) = keymap(state(ms), mode(ms))
keymap_data(ms::MIState, m::ModalInterface) = keymap_data(state(ms), mode(ms))

function prompt!(term::TextTerminal, prompt::ModalInterface, s::MIState = init_state(term, prompt))
    Base.reseteof(term)
    t1 = Threads.@spawn :interactive while true
        wait(s.async_channel)
        status = @lock s.line_modify_lock begin
            fcn = take!(s.async_channel)
            fcn(s)
        end
        status ∈ (:ok, :ignore) || break
    end
    raw!(term, true)
    enable_bracketed_paste(term)
    try
        activate(prompt, s, term, term)
        old_state = mode(s)
        # spawn this because the main repl task is sticky (due to use of @async and _wait2)
        # and we want to not block typing when the repl task thread is busy
        t2 = Threads.@spawn :interactive while true
            eof(term) || peek(term) # wait before locking but don't consume
            @lock s.line_modify_lock begin
                s.n_keys_pressed += 1
                kmap = keymap(s, prompt)
                fcn = match_input(kmap, s)
                kdata = keymap_data(s, prompt)
                s.current_action = :unknown # if the to-be-run action doesn't update this field,
                                            # :unknown will be recorded in the last_action field
                local status
                # errors in keymaps shouldn't cause the REPL to fail, so wrap in a
                # try/catch block
                try
                    status = fcn(s, kdata)
                catch e
                    @error "Error in the keymap" exception=e,catch_backtrace()
                    # try to cleanup and get `s` back to its original state before returning
                    transition(s, :reset)
                    transition(s, old_state)
                    status = :done
                end
                status !== :ignore && (s.last_action = s.current_action)
                if status === :abort
                    s.aborted = true
                    return buffer(s), false, false
                elseif status === :done
                    return buffer(s), true, false
                elseif status === :suspend
                    if Sys.isunix()
                        return buffer(s), true, true
                    end
                else
                    @assert status ∈ (:ok, :ignore)
                end
            end
        end
        return fetch(t2)
    finally
        put!(s.async_channel, Returns(:done))
        wait(t1)
        raw!(term, false) && disable_bracketed_paste(term)
    end
    # unreachable
end


end # module
