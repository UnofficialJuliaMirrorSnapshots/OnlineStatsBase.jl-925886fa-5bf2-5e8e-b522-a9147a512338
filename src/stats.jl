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

#-----------------------------------------------------------------------# CountMap
"""
    CountMap(T::Type)
    CountMap(dict::AbstractDict{T, Int})

Track a dictionary that maps unique values to its number of occurrences.  Similar to
`StatsBase.countmap`.

# Example

    o = fit!(CountMap(Int), rand(1:10, 1000))
    value(o)
    probs(o)
    OnlineStats.pdf(o, 1)
    collect(keys(o))
"""
mutable struct CountMap{T, A <: AbstractDict{T, Int}} <: OnlineStat{T}
    value::A  # OrderedDict by default
    n::Int
end
CountMap{T}() where {T} = CountMap{T, OrderedDict{T,Int}}(OrderedDict{T,Int}(), 0)
CountMap(T::Type = Any) = CountMap{T, OrderedDict{T,Int}}(OrderedDict{T, Int}(), 0)
CountMap(d::D) where {T,D<:AbstractDict{T, Int}} = CountMap{T, D}(d, 0)
function _fit!(o::CountMap, x)
    o.n += 1
    o.value[x] = get!(o.value, x, 0) + 1
end
_merge!(o::CountMap, o2::CountMap) = (merge!(+, o.value, o2.value); o.n += o2.n)
function probs(o::CountMap, kys = keys(o.value))
    out = zeros(Int, length(kys))
    valkeys = keys(o.value)
    for (i, k) in enumerate(kys)
        out[i] = k in valkeys ? o.value[k] : 0
    end
    sum(out) == 0 ? Float64.(out) : out ./ sum(out)
end
pdf(o::CountMap, y) = y in keys(o.value) ? o.value[y] / nobs(o) : 0.0
Base.keys(o::CountMap) = keys(o.value)
nkeys(o::CountMap) = length(o.value)
Base.values(o::CountMap) = values(o.value)
Base.getindex(o::CountMap, i) = o.value[i]

#-----------------------------------------------------------------------# CovMatrix
"""
    CovMatrix(p=0; weight=EqualWeight())
    CovMatrix(::Type{T}, p=0; weight=EqualWeight())

Calculate a covariance/correlation matrix of `p` variables.  If the number of variables is
unknown, leave the default `p=0`.

# Example

    o = fit!(CovMatrix(), randn(100, 4) |> eachrow)
    cor(o)
    cov(o)
    mean(o)
    var(o)
"""
mutable struct CovMatrix{T,W} <: OnlineStat{Union{Tuple, NamedTuple, AbstractVector}} where T<:Number
    value::Matrix{T}
    A::Matrix{T}  # x'x/n
    b::Vector{T}  # 1'x/n
    weight::W
    n::Int
end
function CovMatrix(::Type{T}, p::Int=0; weight = EqualWeight()) where T<:Number
    CovMatrix(zeros(T,p,p), zeros(T,p,p), zeros(T,p), weight, 0)
end
CovMatrix(p::Int=0; weight = EqualWeight()) = CovMatrix(zeros(p,p), zeros(p,p), zeros(p), weight, 0)
function _fit!(o::CovMatrix{T}, x) where {T}
    γ = o.weight(o.n += 1)
    if isempty(o.A)
        p = length(x)
        o.b = zeros(T, p)
        o.A = zeros(T, p, p)
        o.value = zeros(T, p, p)
    end
    smooth!(o.b, x, γ)
    smooth_syr!(o.A, x, γ)
end
nvars(o::CovMatrix) = size(o.A, 1)
function value(o::CovMatrix; corrected::Bool = true)
    o.value[:] = Matrix(Hermitian((o.A - o.b * o.b')))
    corrected && rmul!(o.value, bessel(o))
    o.value
end
function _merge!(o::CovMatrix, o2::CovMatrix)
    γ = o2.n / (o.n += o2.n)
    smooth!(o.A, o2.A, γ)
    smooth!(o.b, o2.b, γ)
end
Statistics.cov(o::CovMatrix; corrected::Bool = true) = value(o; corrected=corrected)
Statistics.mean(o::CovMatrix) = o.b
Statistics.var(o::CovMatrix; kw...) = diag(value(o; kw...))
function Statistics.cor(o::CovMatrix; kw...)
    value(o; kw...)
    v = 1.0 ./ sqrt.(diag(o.value))
    rmul!(o.value, Diagonal(v))
    lmul!(Diagonal(v), o.value)
    o.value
end

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
end
function Extrema(T::Type = Float64)
    a, b, S = extrema_init(T)
    Extrema{T,S}(a, b, 0)
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
end
value(o::Extrema) = (o.min, o.max)
Base.extrema(o::Extrema) = value(o)
Base.maximum(o::Extrema) = o.max
Base.minimum(o::Extrema) = o.min

#-----------------------------------------------------------------------# Group
"""
    Group(stats::OnlineStat...)
    Group(; stats...)
    Group(collection)

Create a vector-input stat from several scalar-input stats.  For a new
observation `y`, `y[i]` is sent to `stats[i]`.

# Examples

    x = randn(100, 2)

    fit!(Group(Mean(), Mean()), eachrow(x))
    fit!(Group(Mean(), Variance()), eachrow(x))

    o = fit!(Group(m1 = Mean(), m2 = Mean()), eachrow(x))
    o.stats.m1
    o.stats.m2
"""
struct Group{T, S} <: StatCollection{S}
    stats::T
    function Group(stats::T) where {T}
        inputs = map(input, stats)
        tup = Tuple{inputs...}
        S = Union{tup, NamedTuple{names, R} where R<:tup, AbstractVector{<: promote_type(inputs...)}} where names
        new{T,S}(stats)
    end
end
Group(o::OnlineStat...) = Group(o)
Group(;o...) = Group(o.data)
nobs(o::Group) = nobs(first(o.stats))
Base.:(==)(a::Group, b::Group) = all(a.stats .== b.stats)

Base.getindex(o::Group, i) = o.stats[i]
Base.first(o::Group) = first(o.stats)
Base.last(o::Group) = last(o.stats)
Base.lastindex(o::Group) = length(o)
Base.length(o::Group) = length(o.stats)
Base.values(o::Group) = map(value, o.stats)

Base.iterate(o::Group) = (o.stats[1], 2)
Base.iterate(o::Group, i) = i > length(o) ? nothing : (o.stats[i], i + 1)

@generated function _fit!(o::Group{T}, y) where {T}
    N = fieldcount(T)
    :(Base.Cartesian.@nexprs $N i -> @inbounds(_fit!(o.stats[i], y[i])))
end
function _fit!(o::Group{T}, y) where {T<:AbstractVector}
    for (i,yi) in enumerate(y)
        _fit!(o.stats[i], yi)
    end
end

_merge!(o::Group, o2::Group) = map(merge!, o.stats, o2.stats)

Base.:*(n::Integer, o::OnlineStat) = Group([copy(o) for i in 1:n]...)


#-----------------------------------------------------------------------# GroupBy
"""
    GroupBy{T}(stat)
    GroupBy(T, stat)

Update `stat` for each group (of type `T`).  A single observation is either a (named)
tuple with two elements or a Pair.

# Example

    x = rand(1:10, 10^5)
    y = x .+ randn(10^5)
    fit!(GroupBy{Int}(Extrema()), zip(x,y))
"""
mutable struct GroupBy{T, S, O <: OnlineStat{S}} <: OnlineStat{TwoThings{T,S}}
    value::OrderedDict{T, O}
    init::O
    n::Int
    function GroupBy(value::OrderedDict{T,O}, init::O, n::Int) where {T,S,O<:OnlineStat{S}}
        new{T,S,O}(value, init, n)
    end
end
GroupBy(T::Type, stat::O) where {O<:OnlineStat} = GroupBy(OrderedDict{T, O}(), stat, 0)
function _fit!(o::GroupBy, xy)
    o.n += 1
    x, y = xy
    x in keys(o.value) ? fit!(o.value[x], y) : (o.value[x] = fit!(copy(o.init), y))
end
Base.getindex(o::GroupBy{T}, i::T) where {T} = o.value[i]
function Base.show(io::IO, o::GroupBy{T,S,O}) where {T,S,O}
    print(io, name(o, false, false) * ": $T => $O")
    for (i, (k,v)) in enumerate(o.value)
        char = i == length(o.value) ?  '└' : '├'
        print(io, "\n  $(char)── $k: $v")
    end
end
function _merge!(a::GroupBy{T,O}, b::GroupBy{T,O}) where {T,O}
    a.init == b.init || error("Cannot merge GroupBy objects with different inits")
    a.n += b.n
    merge!((o1, o2) -> merge!(o1, o2), a.value, b.value)
end

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

#-----------------------------------------------------------------------# Moments
"""
    Moments(; weight=EqualWeight())

First four non-central moments.

# Example

    o = fit!(Moments(), randn(1000))
    mean(o)
    var(o)
    std(o)
    skewness(o)
    kurtosis(o)
"""
mutable struct Moments{W} <: OnlineStat{Number}
    m::Vector{Float64}
    weight::W
    n::Int
end
Moments(;weight = EqualWeight()) = Moments(zeros(4), weight, 0)
function _fit!(o::Moments, y::Real)
    γ = o.weight(o.n += 1)
    y2 = y * y
    @inbounds o.m[1] = smooth(o.m[1], y, γ)
    @inbounds o.m[2] = smooth(o.m[2], y2, γ)
    @inbounds o.m[3] = smooth(o.m[3], y * y2, γ)
    @inbounds o.m[4] = smooth(o.m[4], y2 * y2, γ)
end
Statistics.mean(o::Moments) = o.m[1]
function Statistics.var(o::Moments; corrected=true)
    out = (o.m[2] - o.m[1] ^ 2)
    corrected ? bessel(o) * out : out
end
function StatsBase.skewness(o::Moments)
    v = value(o)
    vr = o.m[2] - o.m[1]^2
    (v[3] - 3.0 * v[1] * vr - v[1] ^ 3) / vr ^ 1.5
end
function StatsBase.kurtosis(o::Moments)
    # v = value(o)
    # (v[4] - 4.0 * v[1] * v[3] + 6.0 * v[1] ^ 2 * v[2] - 3.0 * v[1] ^ 4) / var(o) ^ 2 - 3.0
    m1, m2, m3, m4 = value(o)
    (m4 - 4.0 * m1 * m3 + 6.0 * m1^2 * m2 - 3.0 * m1 ^ 4) / var(o; corrected=false) ^ 2 - 3.0
end
function _merge!(o::Moments, o2::Moments)
    γ = o2.n / (o.n += o2.n)
    smooth!(o.m, o2.m, γ)
end

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
end
value(o::Variance) = o.n > 1 ? o.σ2 * bessel(o) : 1.0
Statistics.var(o::Variance) = value(o)
Statistics.mean(o::Variance) = o.μ


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

Create an FTSeries and specify the type `T` of the pre-transformed values.

# Example

    o = FTSeries(Mean(), Variance(); transform=abs)
    fit!(o, -rand(1000))

    # Remove missing values represented as DataValues
    using DataValues
    y = DataValueArray(randn(100), rand(Bool, 100))
    o = FTSeries(DataValue, Mean(); transform=get, filter=!isna)
    fit!(o, y)

    # Remove missing values represented as Missing
    y = [rand(Bool) ? rand() : missing for i in 1:100]
    o = FTSeries(Mean(); filter=!ismissing)
    fit!(o, y)

    # Alternatively for Missing:
    fit!(Mean(), skipmissing(y))
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
end

