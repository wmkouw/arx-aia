"""
Experiment description


Wouter M. Kouw
2024-mar-11
"""

using Pkg
Pkg.activate(".")
Pkg.instantiate()

using Revise
using LinearAlgebra
using Distributions
using RxInfer
using ExponentialFamily
using Plots
default(label="", margin=10Plots.pt)
includet("../systems/Pendulums.jl"); using .Pendulums
# includet("../src/nuv_box.jl");
# includet("../src/diode.jl");
# includet("../src/buffer.jl");
includet("../distributions/mv_normal_gamma.jl")
includet("../distributions/location_scale_tdist.jl")
includet("../nodes/mv_normal_gamma.jl")
# includet("../nodes/location_scale_tdist.jl")
includet("../nodes/mv_location_scale_tdist.jl")
includet("../nodes/arx.jl")
includet("../nodes/arxefe.jl")
includet("../src/util.jl")

## System specification

sys_mass = 1.0
sys_length = 1.0
sys_damping = 0.00
sys_mnoise_stdev = 1e-3
sys_ulims = (-10., 10.)
Δt = 0.1

init_state = [0.0, 0.0]
pendulum = SPendulum(init_state = init_state, 
                     mass = sys_mass, 
                     length = sys_length, 
                     damping = sys_damping, 
                     mnoise_sd = sys_mnoise_stdev, 
                     torque_lims = sys_ulims,
                     Δt=Δt)

N = 3000
tsteps = range(0.0, step=Δt, length=N)                     

A  = rand(10)
Ω  = rand(10)*3
controls = mean([A[i]*sin.(Ω[i].*tsteps) for i = 1:10]) ./ 20;

states = zeros(2,N)
observations = zeros(N)
torques = zeros(N)

for k in 1:N
    states[:,k] = pendulum.state
    observations[k] = pendulum.sensor
    step!(pendulum, controls[k])
    torques[k] = pendulum.torque
end

p11 = plot(ylabel="angle")
plot!(tsteps, states[1,:], color="blue", label="state")
scatter!(tsteps, observations, color="black", label="measurements")
p12 = plot(xlabel="time [s]", ylabel="torque")
plot!(tsteps, controls[:], color="red")
plot!(tsteps, torques[:], color="purple")
p10 = plot(p11,p12, layout=grid(2,1, heights=[0.7, 0.3]), size=(900,600))

savefig(p10, "experiments/figures/simsys.png")

## Online system identification

@model function ARXID()

    yk = datavar(Float64) where { allow_missing = true }
    xk = datavar(Vector{Float64})
    μk = datavar(Vector{Float64})
    Λk = datavar(Matrix{Float64})
    αk = datavar(Float64)
    βk = datavar(Float64)

    # Parameter prior
    ζ ~ MvNormalGamma(μk,Λk,αk,βk)

    # Autoregressive likelihood
    yk ~ ARX(xk,ζ)
end

@model function ARXAgent(η)

    m_star = datavar(Float64)
    v_star = datavar(Float64)

    yk = datavar(Float64) where { allow_missing = true }
    xk = datavar(Vector{Float64})
    μk = datavar(Vector{Float64})
    Λk = datavar(Matrix{Float64})
    αk = datavar(Float64)
    βk = datavar(Float64)

    # Parameter prior
    ζk ~ MvNormalGamma(μk,Λk,αk,βk)

    # Autoregressive likelihood
    yk ~ ARXEFE(uk,xk, ζk)

    # Prevent updating of parameters
    # ζt ~ Diode(ζk)

    # Control prior
    ut ~ NormalMeanPrecision(0.0, η)

    # Future likelihood
    ut ~ ARXEFE(m_star, v_star, yk, ζk)

end

My = 1
Mu = 0
M = My+Mu+1
ybuffer = zeros(My)
ubuffer = zeros(Mu+1)
yk = observations[1]

m_star = 1.0
v_star = 0.1

ppy = []
pu  = []
pζ  = [MvNormalGamma(1e-1*ones(M), 1e-2diagm(ones(M)), 2., 100.)]
     
for k = 1:N

    # Full buffer
    xk = [ybuffer; ubuffer]

    # Extract parameters
    μk,Λk,αk,βk = BayesBase.params(pζ[end])

    # Make prediction
    results = infer(
        model = ARXID(),
        data = (yk=missing, xk=xk, μk=μk, Λk=Λk, αk=αk, βk=βk),
    )
    push!(ppy, results.predictions[:yk])

    # Update parameter belief
    results = infer(
        model = ARXID(),
        data = (yk=observations[k], xk=xk, μk=μk, Λk=Λk, αk=αk, βk=βk),
    )
    push!(pζ, results.posteriors[:ζ])

    # Infer control
    results = infer(
        model = ARXAgent(),
        data = (yk=observations[k], xk=xk, μk=μk, Λk=Λk, αk=αk, βk=βk),
    )
    push!(pu, results.posteriors[:ut])

    # Update buffers    
    ybuffer = backshift(ybuffer,observations[k])
    ubuffer = backshift(ubuffer,torques[k])

end


p20 = plot(ylabel="angle")
plot!(tsteps, states[1,:], color="blue", label="state")
scatter!(tsteps, observations, color="black", label="measurements")
plot!(tsteps, mean.(ppy), ribbon=std.(ppy), color="purple", label="predictions")
p21 = plot(ylabel="squared error", xlabel="time (s)")
plot!(tsteps, (states[1,:] .- mean.(ppy)).^2, color="orange")
plot(p20,p21, layout=(2,1), size=(900,600))

savefig(p20, "experiments/figures/pred-idsys.png")

μ_series = cat(mean.(pζ)...,dims=2)
plot([-Δt; tsteps], μ_series')


