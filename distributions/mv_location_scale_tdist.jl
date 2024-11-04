
import BayesBase
using LinearAlgebra
using Distributions
using RxInfer
using SpecialFunctions



struct MvLocationScaleT{T, N <: Real, M <: AbstractVector{T}, S <: AbstractMatrix{T}} <: ContinuousMultivariateDistribution
 
    ν::N # Degrees-of-freedom
    μ::M # Mean vector
    Σ::S # Covariance matrix

    function MvLocationScaleT(ν::N, μ::M, Σ::S) where {T, N <: Real, M <: AbstractVector{T}, S <: AbstractMatrix{T}}
        
        if ν <= 0.0; error("Degrees of freedom parameter must be positive."); end
        if length(μ) !== size(Σ,1); error("Dimensionalities of mean and covariance matrix don't match."); end

        return new{T,N,M,S}(ν, μ, Σ)
    end
end

BayesBase.params(p::MvLocationScaleT) = (p.ν, p.μ, p.Σ)
BayesBase.dim(p::MvLocationScaleT) = length(p.μ)
BayesBase.mean(p::MvLocationScaleT) = p.μ
# BayesBase.cov(p::MvLocationScaleT) = p.Σ
# BayesBase.precision(p::LocationScaleT) = inv(var(p))

function pdf(p::MvLocationScaleT, x)
    d = dims(p)
    ν, μ, Σ = params(p)
    return sqrt(1/( (ν*π)^d*det(Σ) )) * gamma((ν+d)/2)/gamma(ν/2) * (1 + 1/ν*(x-μ)'*inv(Σ)*(x-μ))^(-(ν+d)/2)
end

function logpdf(p::MvLocationScaleT, x)
    d = dims(p)
    ν, μ, Σ = params(p)
    return -d/2*log(ν*π) - 1/2*logdet(Σ) +loggamma((ν+d)/2) -loggamma(ν/2) -(ν+d)/2*log(1 + 1/ν*(x-μ)'*inv(Σ)*(x-μ))
end
