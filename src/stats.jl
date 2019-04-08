#-----------------------------------------------------------------------# Counter
"""
    Counter(T=Number)

Count the number of items in a data stream with elements of type `T`.

# Example

    fit!(Counter(Int), 1:100)
"""
mutable struct Counter{T} <: OnlineStat{T}
    n::Int
    Counter{T}() where {T} = new{T}(0)
end
Counter(T = Number) = Counter{T}()
_fit!(o::Counter{T}, y) where {T} = (o.n += 1)
_merge!(a::Counter, b::Counter) = (a.n += b.n)

#-----------------------------------------------------------------------# Extrema
"""
    Extrema(T::Type = Float64)

Maximum and minimum.

# Example

    o = fit!(Extrema(), rand(10^5))
    extrema(o)
    maximum(o)
    minimum(o)
"""
# T is type to store data, S is type of single observation.
# E.g. you may want to accept any Number even if you are storing values as Float64
mutable struct Extrema{T,S} <: OnlineStat{S}
    min::T
    max::T
    n::Int
    function Extrema(T::Type = Float64)
        a, b, S = extrema_init(T)
        new{T,S}(a, b, 0)
    end
end
extrema_init(T::Type{<:Number}) = typemax(T), typemin(T), Number
extrema_init(T::Type{String}) = "", "", String
extrema_init(T::Type{Date}) = typemax(Date), typemin(Date), Date
extrema_init(T::Type) = rand(T), rand(T), T
function _fit!(o::Extrema, y)
    (o.n += 1) == 1 && (o.min = o.max = y)
    o.min = min(o.min, y)
    o.max = max(o.max, y)
end
function _merge!(o::Extrema, o2::Extrema)
    o.min = min(o.min, o2.min)
    o.max = max(o.max, o2.max)
    o.n += o2.n
    o
end
value(o::Extrema) = (o.min, o.max)
Base.extrema(o::Extrema) = value(o)
Base.maximum(o::Extrema) = o.max
Base.minimum(o::Extrema) = o.min

#-----------------------------------------------------------------------# Mean
"""
    Mean(T = Float64; weight=EqualWeight())

Track a univariate mean, stored as type `T`.

# Example

    @time fit!(Mean(), randn(10^6))
"""
mutable struct Mean{T,W} <: OnlineStat{Number}
    μ::T
    weight::W
    n::Int
end
Mean(T::Type{<:Number} = Float64; weight = EqualWeight()) = Mean(zero(T), weight, 0)
_fit!(o::Mean{T}, x) where {T} = (o.μ = smooth(o.μ, x, T(o.weight(o.n += 1))))
function _merge!(o::Mean, o2::Mean)
    o.n += o2.n
    o.μ = smooth(o.μ, o2.μ, o2.n / o.n)
end
Statistics.mean(o::Mean) = o.μ
Base.copy(o::Mean) = Mean(o.μ, o.weight, o.n)

#-----------------------------------------------------------------------# Sum
"""
    Sum(T::Type = Float64)

Track the overall sum.

# Example

    fit!(Sum(Int), fill(1, 100))
"""
mutable struct Sum{T} <: OnlineStat{Number}
    sum::T
    n::Int
end
Sum(T::Type = Float64) = Sum(T(0), 0)
Base.sum(o::Sum) = o.sum
_fit!(o::Sum{T}, x::Real) where {T<:AbstractFloat} = (o.sum += convert(T, x); o.n += 1)
_fit!(o::Sum{T}, x::Real) where {T<:Integer} =       (o.sum += round(T, x); o.n += 1)
_merge!(o::T, o2::T) where {T <: Sum} = (o.sum += o2.sum; o.n += o2.n; o)

#-----------------------------------------------------------------------# Variance
"""
    Variance(T = Float64; weight=EqualWeight())

Univariate variance, tracked as type `T`.

# Example

    o = fit!(Variance(), randn(10^6))
    mean(o)
    var(o)
    std(o)
"""
mutable struct Variance{T, W} <: OnlineStat{Number}
    σ2::T
    μ::T
    weight::W
    n::Int
end
function Variance(T::Type{<:Number} = Float64; weight = EqualWeight())
    Variance(zero(T), zero(T), weight, 0)
end
Base.copy(o::Variance) = Variance(o.σ2, o.μ, o.weight, o.n)
function _fit!(o::Variance{T}, x) where {T}
    μ = o.μ
    γ = T(o.weight(o.n += 1))
    o.μ = smooth(o.μ, T(x), γ)
    o.σ2 = smooth(o.σ2, (T(x) - o.μ) * (T(x) - μ), γ)
end
function _merge!(o::Variance, o2::Variance)
    γ = o2.n / (o.n += o2.n)
    δ = o2.μ - o.μ
    o.σ2 = smooth(o.σ2, o2.σ2, γ) + δ ^ 2 * γ * (1.0 - γ)
    o.μ = smooth(o.μ, o2.μ, γ)
    o
end
value(o::Variance) = o.n > 1 ? o.σ2 * bessel(o) : 1.0
Statistics.var(o::Variance) = value(o)
Statistics.mean(o::Variance) = o.μ


#-----------------------------------------------------# StatCollection (Series and Group)
abstract type StatCollection{T} <: OnlineStat{T} end

function Base.show(io::IO, o::StatCollection)
    print(io, name(o, false, false))
    print_stat_tree(io, o.stats)
end

function print_stat_tree(io::IO, stats)
    for (i, stat) in enumerate(stats)
        char = i == length(stats) ? '└' : '├'
        print(io, "\n  $(char)── $stat")
    end
end

#-----------------------------------------------------------------------# Series
"""
    Series(stats)
    Series(stats...)
    Series(; stats...)

Track a collection stats for one data stream.

# Example

    s = Series(Mean(), Variance())
    fit!(s, randn(1000))
"""
struct Series{IN, T} <: StatCollection{IN}
    stats::T
    Series(stats::T) where {T} = new{Union{map(input, stats)...}, T}(stats)
end
Series(t::OnlineStat...) = Series(t)
Series(; t...) = Series(t.data)

value(o::Series) = map(value, o.stats)
nobs(o::Series) = nobs(o.stats[1])
@generated function _fit!(o::Series{IN, T}, y) where {IN, T}
    n = length(fieldnames(T))
    :(Base.Cartesian.@nexprs $n i -> _fit!(o.stats[i], y))
end
_merge!(o::Series, o2::Series) = map(_merge!, o.stats, o2.stats)

#-----------------------------------------------------------------------# FTSeries
"""
    FTSeries(stats...; filter=x->true, transform=identity)

Track multiple stats for one data stream that is filtered and transformed before being
fitted.

    FTSeries(T, stats...; filter, transform)

Create an FTSeries and specify the type `T` of the transformed values.

# Example

    o = FTSeries(Mean(), Variance(); transform=abs)
    fit!(o, -rand(1000))

    # Remove missing values represented as DataValues
    using DataValues
    y = DataValueArray(randn(100), rand(Bool, 100))
    o = FTSeries(DataValue, Mean(); transform=get, filter=!isna)
    fit!(o, y)
"""
mutable struct FTSeries{IN, OS, F, T} <: StatCollection{Union{IN,Missing}}
    stats::OS
    filter::F
    transform::T
    nfiltered::Int
end
function FTSeries(stats::OnlineStat...; filter=x->true, transform=identity)
    IN, OS = Union{map(input, stats)...}, typeof(stats)
    FTSeries{IN, OS, typeof(filter), typeof(transform)}(stats, filter, transform, 0)
end
function FTSeries(T::Type, stats::OnlineStat...; filter=x->true, transform=identity)
    FTSeries{T, typeof(stats), typeof(filter), typeof(transform)}(stats, filter, transform, 0)
end
value(o::FTSeries) = value.(o.stats)
nobs(o::FTSeries) = nobs(o.stats[1])
@generated function _fit!(o::FTSeries{N, OS}, y) where {N, OS}
    n = length(fieldnames(OS))
    quote
        if o.filter(y)
            yt = o.transform(y)
            Base.Cartesian.@nexprs $n i -> @inbounds begin
                _fit!(o.stats[i], yt)
            end
        else
            o.nfiltered += 1
        end
    end
end
function _merge!(o::FTSeries, o2::FTSeries)
    o.nfiltered += o2.nfiltered
    _merge!.(o.stats, o2.stats)
    o
end

