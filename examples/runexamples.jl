using Test

@testset "TinyModia examples with simulation" begin

include("SimpleFilters.jl")  
include("FilterCircuit.jl")    
include("CauerLowPassFilter.jl")    
include("Rectifier.jl")   
include("MotorControl.jl")    
include("Pendulum.jl")   
include("ServoSystem.jl")

end
