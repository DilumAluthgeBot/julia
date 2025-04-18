# This file is a part of Julia. License is MIT: https://julialang.org/license

using Test

f = Float16(2.)
g = Float16(1.)
@testset "comparisons" begin
    @test f >= g
    @test f > g
    @test g < f
    @test g <= g
    @test all([g g] .< [f f])
    @test all([g g] .<= [f f])
    @test all([f f] .> [g g])
    @test all([f f] .>= [g g])
    @test isless(g, f)
    @test !isless(f, g)

    @test Float16(2.5) == Float16(2.5)
    @test Float16(2.5) != Float16(2.6)
    @test isequal(Float16(0.0), Float16(0.0))
    @test !isequal(Float16(-0.0), Float16(0.0))
    @test !isequal(Float16(0.0), Float16(-0.0))

    for T = Base.BitInteger_types
        @test -Inf16 < typemin(T)
        @test -Inf16 <= typemin(T)
        @test typemin(T) > -Inf16
        @test typemin(T) >= -Inf16
        @test typemin(T) != -Inf16

        @test Inf16 > typemax(T)
        @test Inf16 >= typemax(T)
        @test typemax(T) < Inf16
        @test typemax(T) <= Inf16
        @test typemax(T) != Inf16
    end
end

@testset "convert" begin
    @test convert(Bool,Float16(0.0)) == false
    @test convert(Bool,Float16(1.0)) == true
    @test_throws InexactError convert(Bool,Float16(0.1))

    @test convert(Int128,Float16(-2.0)) == Int128(-2)
    @test convert(UInt128,Float16(2.0)) == UInt128(2)

    # convert(::Type{Int128},  x::Float16)
    @test convert(Int128, Float16(1.0)) === Int128(1.0)
    @test convert(Int128, Float16(-1.0)) === Int128(-1.0)
    @test_throws InexactError convert(Int128, Float16(3.5))

    # convert(::Type{UInt128}, x::Float16)
    @test convert(UInt128, Float16(1.0)) === UInt128(1.0)
    @test_throws InexactError convert(UInt128, Float16(3.5))
    @test_throws InexactError convert(UInt128, Float16(-1))

    @test convert(Int128,Float16(-1.0)) == Int128(-1)
    @test convert(UInt128,Float16(5.0)) == UInt128(5)
end

@testset "round, trunc, float, ceil" begin
    @test round(Int,Float16(0.5f0)) == round(Int,0.5f0)
    @test trunc(Int,Float16(0.9f0)) === trunc(Int,0.9f0) === 0
    @test floor(Int,Float16(0.9f0)) === floor(Int,0.9f0) === 0
    @test trunc(Int,Float16(1)) === 1
    @test floor(Int,Float16(1)) === 1
    @test ceil(Int,Float16(0.1f0)) === ceil(Int,0.1f0) === 1
    @test ceil(Int,Float16(0)) === ceil(Int,0) === 0
    @test round(Float16(0.1f0)) == round(0.1f0) == 0
    @test round(Float16(0.9f0)) == round(0.9f0) == 1
    @test trunc(Float16(0.9f0)) == trunc(0.9f0) == 0
    @test floor(Float16(0.9f0)) == floor(0.9f0) == 0
    @test trunc(Float16(1)) === Float16(1)
    @test floor(Float16(1)) === Float16(1)
    @test ceil(Float16(0.1)) == ceil(0.1)
    @test ceil(Float16(0.9)) == ceil(0.9)
    @test unsafe_trunc(UInt8, Float16(3)) === 0x03
    @test unsafe_trunc(Int16, Float16(3)) === Int16(3)
    @test unsafe_trunc(UInt128, Float16(3)) === UInt128(3)
    @test unsafe_trunc(Int128, Float16(3)) === Int128(3)
    # `unsafe_trunc` of `NaN` can be any value, see #56582
    @test unsafe_trunc(Int16, NaN16) isa Int16 # #18771
end
@testset "fma and muladd" begin
    @test fma(Float16(0.1),Float16(0.9),Float16(0.5)) ≈ fma(0.1,0.9,0.5)
    @test muladd(Float16(0.1),Float16(0.9),Float16(0.5)) ≈ muladd(0.1,0.9,0.5)
end
@testset "unary ops" begin
    @test -f === Float16(-2.)
    @test Float16(0.5f0)^2 ≈ Float16(0.5f0^2)
    @test sin(f) ≈ sin(2f0)
    @test log10(Float16(100)) == Float16(2.0)
    @test sin(ComplexF16(f)) ≈ sin(complex(2f0))

    # no domain error is thrown for negative values
    @test cbrt(Float16(-1.0)) == -1.0
    # test zero and Inf
    @test cbrt(Float16(0.0)) == Float16(0.0)
    @test cbrt(Inf16) == Inf16
end
@testset "binary ops" begin
    @test f+g === Float16(3f0)
    @test f-g === Float16(1f0)
    @test f*g === Float16(2f0)
    @test f/g === Float16(2f0)
    @test f^g === Float16(2f0)
    @test f^1 === Float16(2f0)
    @test f^-g === Float16(0.5f0)

    @test f + 2 === Float16(4f0)
    @test f - 2 === Float16(0f0)
    @test f*2 === Float16(4f0)
    @test f/2 === Float16(1f0)
    @test f + 2. === 4.
    @test f - 2. === 0.
    @test f*2. === 4.
    @test f/2. === 1.
end

@testset "NaN16 and Inf16" begin
    @test isnan(NaN16)
    @test isnan(-NaN16)
    @test !isnan(Inf16)
    @test !isnan(-Inf16)
    @test !isnan(Float16(2.6))
    @test NaN16 != NaN16
    @test isequal(NaN16, NaN16)
    @test repr(NaN16) == "NaN16"
    @test sprint(show, NaN16, context=:compact => true) == "NaN"

    @test isinf(Inf16)
    @test isinf(-Inf16)
    @test !isinf(NaN16)
    @test !isinf(-NaN16)
    @test !isinf(Float16(2.6))
    @test Inf16 == Inf16
    @test Inf16 != -Inf16
    @test -Inf16 < Inf16
    @test isequal(Inf16, Inf16)
    @test repr(Inf16) == "Inf16"
    @test sprint(show, Inf16, context=:compact => true) == "Inf"

    @test isnan(reinterpret(Float16,0x7c01))
    @test !isinf(reinterpret(Float16,0x7c01))

    @test nextfloat(Inf16) === Inf16
    @test prevfloat(-Inf16) === -Inf16
end

@test repr(Float16(44099)) == "Float16(4.41e4)"

@testset "signed zeros" begin
    for z1 in (Float16(0.0), Float16(-0.0)), z2 in (Float16(0.0), Float16(-0.0))
        @test z1 == z2
        @test isequal(z1, z1)
        @test z1 === z1
        for elty in (Float32, Float64)
            z3 = convert(elty, z2)
            @test z1==z3
        end
    end
end

@testset "rounding in conversions" begin
    for f32 in [.3325f0, -.3325f0]
        f16 = Float16(f32)
        # need to round away from 0. make sure we picked closest number.
        @test abs(f32 - f16) < abs(f32 - nextfloat(f16))
        @test abs(f32 - f16) < abs(f32 - prevfloat(f16))
    end
    # halfway between and last bit is 1
    ff = reinterpret(Float32,                           0b00111110101010100011000000000000)
    @test Float32(Float16(ff)) === reinterpret(Float32, 0b00111110101010100100000000000000)
    # halfway between and last bit is 0
    ff = reinterpret(Float32,                           0b00111110101010100001000000000000)
    @test Float32(Float16(ff)) === reinterpret(Float32, 0b00111110101010100000000000000000)

    for x = (typemin(Int64), typemin(Int128)), R = (RoundUp, RoundToZero)
        @test Float16(x, R) == nextfloat(-Inf16)
    end
end

# issue #5948
@test string(reinterpret(Float16, 0x7bff)) == "6.55e4"

#  #9939 (and #9897)
@test rationalize(Float16(0.1)) == 1//10

# issue #17148
@test rem(Float16(1.2), Float16(one(1.2))) == 0.20019531f0

# issue #32441
const f16eps2 = Float32(eps(Float16(0.0)))/2
const minsubf16 = nextfloat(Float16(0.0))
const minsubf16_32 = Float32(minsubf16)
@test Float16(f16eps2) == Float16(0.0)
@test Float16(nextfloat(f16eps2)) == minsubf16
@test Float16(prevfloat(minsubf16_32)) == minsubf16
# Ties to even, in this case up
@test Float16(minsubf16_32 + f16eps2) == nextfloat(minsubf16)
@test Float16(prevfloat(minsubf16_32 + f16eps2)) == minsubf16

# issues #33076
@test Float16(1f5) == Inf16

# issue #52394
@test Float16(10^8 // (10^9 + 1)) == convert(Float16, 10^8 // (10^9 + 1)) == Float16(0.1)
@test Float16((typemax(UInt128)-0x01) // typemax(UInt128)) == Float16(1.0)
@test Float32((typemax(UInt128)-0x01) // typemax(UInt128)) == Float32(1.0)

@testset "conversion to Float16 from" begin
    for T in (Float32, Float64, BigFloat)
        @testset "conversion from $T" begin
            for i in 1:2^16
                f = reinterpret(Float16, UInt16(i-1))
                isfinite(f) || continue
                if f < 0
                    epsdown = T(eps(f))/2
                    epsup   = issubnormal(f) ? epsdown : T(eps(nextfloat(f)))/2
                else
                    epsup   = T(eps(f))/2
                    epsdown = issubnormal(f) ? epsup : T(eps(prevfloat(f)))/2
                end
                @test isequal(f*(-1)^(f === Float16(0)),  Float16(nextfloat(T(f) - epsdown)))
                @test isequal(f*(-1)^(f === -Float16(0)), Float16(prevfloat(T(f) + epsup)))
                @test isequal(prevfloat(f), Float16(prevfloat(T(f) - epsdown)))
                @test isequal(nextfloat(f), Float16(nextfloat(T(f) + epsup)))
            end
        end
    end
end
