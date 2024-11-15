"""
Experiment ARX-EFE MP

Wouter M. Kouw
"""

using Pkg
Pkg.activate(".")
Pkg.instantiate()

using Revise
using LinearAlgebra
using Distributions
using RxInfer
using ExponentialFamily
using ExponentialFamilyProjection
using Plots
default(label="", margin=10Plots.pt)
includet("../../systems/Pendulums.jl"); using .Pendulums

includet("../../distributions/mv_normal_gamma.jl")
includet("../../distributions/location_scale_t.jl")
includet("../../distributions/mv_location_scale_t.jl")
includet("../../distributions/continuous_univariate.jl")

includet("../../nodes/mv_normal_gamma.jl")
includet("../../nodes/location_scale_t.jl")
includet("../../nodes/mv_location_scale_t.jl")
includet("../../nodes/arxefe.jl")
includet("../../nodes/nuv_box.jl")

includet("../../rules/mv_normal_gamma/out.jl")
includet("../../rules/location_scale_t/out.jl")
includet("../../rules/mv_location_scale_t/out.jl")
includet("../../rules/arx_efe/out.jl")
includet("../../rules/arx_efe/in.jl")
includet("../../rules/arx_efe/parameter.jl")
includet("../../rules/NUV_box/out.jl")
includet("../../rules/NUV_box/sigma.jl")

includet("../../src/product.jl")
includet("../../src/util.jl")

## System specification

sys_mass = 0.8
sys_length = 0.5
sys_damping = 0.01
sys_mnoise_stdev = 1e-2
sys_ulims = (-1., 1.)
Δt = 0.05

init_state = [0.0, 0.0]
pendulum = SPendulum(init_state = init_state, 
                     mass = sys_mass, 
                     length = sys_length, 
                     damping = sys_damping, 
                     mnoise_sd = sys_mnoise_stdev, 
                     torque_lims = sys_ulims,
                     Δt=Δt)


## Adaptive control

@model function ARXAgent(yk,ykmin1,ykmin2,uk,ukmin1,ukmin2, μkmin1,Λkmin1,αkmin1,βkmin1,m_star,v_star)

    # Parameter prior
    ζ ~ MvNormalGamma(μkmin1, Λkmin1, αkmin1, βkmin1)

    # Autoregressive likelihood
    yk ~ ARXEFE(ykmin1,ykmin2,uk,ukmin1,ukmin2,ζ)

    # Control prior
    σ2a ~ Uninformative()
    σ2b ~ Uninformative()
    ut ~ NUV_Box(σ2a, σ2b, sys_ulims[1], sys_ulims[2], 1.)

    # Future likelihood
    yt ~ ARXEFE(yk,ykmin1,ut,uk,ukmin1,ζ)

    # Goal prior
    yt ~ NormalMeanVariance(m_star, v_star)

end

constraints = @constraints begin
    q(ut,σ2a,σ2b) = q(ut)q(σ2a)q(σ2b)
end

inits = @initialization begin
    q(σ2a) = PointMass(1.)
    q(σ2b) = PointMass(1.)
    q(ut)  = NormalMeanVariance(0.,1.)
    q(yt)  = LocationScaleT(1.,0.,1.)
end

len_trial = 30
My = 2
Mu = 2
M = My+Mu+1
μ_kmin1 = zeros(M)
Λ_kmin1 = diageye(M)
α_kmin1 = 1.0
β_kmin1 = 1e4
m_star = 0.0
v_star = 1e-1

states       = zeros(2, len_trial)
observations = zeros(len_trial)
torques      = zeros(len_trial)
μs           = zeros(M,len_trial)
Λs           = zeros(M,M,len_trial)
αs           = zeros(len_trial)
βs           = zeros(len_trial)
py           = []
pu           = []

results = []

for k in M:len_trial

    # Track system
    states[:,k] = pendulum.state
    observations[k] = pendulum.sensor

    # Infer parameters,action
    results = infer(
        model          = ARXAgent(μkmin1=μ_kmin1,
                                  Λkmin1=Λ_kmin1,
                                  αkmin1=α_kmin1,
                                  βkmin1=β_kmin1,
                                  m_star=m_star,
                                  v_star=v_star),
        data           = (yk     = observations[k],
                          ykmin1 = observations[k-1], 
                          ykmin2 = observations[k-2],
                          uk     = torques[k],
                          ukmin1 = torques[k-1], 
                          ukmin2 = torques[k-2]),
        constraints    = constraints,
        initialization = inits,
        options        = (limit_stack_depth = 100,),
        iterations     = 10,
        showprogress   = true,
        returnvars     = (yt = KeepLast(),
                          ut = KeepLast(),
                          ζ  = KeepLast(),),
    )

    # Take action
    put_box = ContinuousUnivariateLogPdf(Interval(sys_ulims...), 
                                         results.posteriors[:ut].logpdf)
    action = mode(put_box)
    step!(pendulum, action)
    
    # Track variables
    torques[k] = pendulum.torque
    push!(pu, put_box)
    push!(py, results.posteriors[:yt])
    μs[:,k]   = μ_kmin1 = mean(results.posteriors[:ζ])
    Λs[:,:,k] = Λ_kmin1 = precision(results.posteriors[:ζ])
    αs[k]     = α_kmin1 = shape(results.posteriors[:ζ])
    βs[k]     = β_kmin1 = rate(results.posteriors[:ζ])

end

tsteps = range(0, step=Δt, length=len_trial)

p101 = plot(xlabel="time", ylabel="angle")
scatter!(tsteps, observations, label="observations")
plot!(collect(tsteps[M:end]), mean.(py), ribbon=std.(py), label="predictions")

p102 = plot(xlabel="time", ylabel="control", ylims=sys_ulims)
plot!(tsteps, torques, label="torques")
plot!(collect(tsteps[M:end]), mode.(pu), ribbon=std.(pu), label="Control posteriors")

plot(p101, p102, layout=(2,1), size=(500,1000))
savefig("experiments/swingup/figures/swingup-trial.png")


