using QuantumClifford
using JET
using ArrayInterface
using Static
using Graphs
using LinearAlgebra
using Polyester

using JET: ReportPass, BasicPass, InferenceErrorReport, UncaughtExceptionReport

# Custom report pass that ignores `UncaughtExceptionReport`
# Too coarse currently, but it serves to ignore the various
# "may throw" messages for runtime errors we raise on purpose
# (mostly on malformed user input)
struct MayThrowIsOk <: ReportPass end

# ignores `UncaughtExceptionReport` analyzed by `JETAnalyzer`
(::MayThrowIsOk)(::Type{UncaughtExceptionReport}, @nospecialize(_...)) = return

# forward to `BasicPass` for everything else
function (::MayThrowIsOk)(report_type::Type{<:InferenceErrorReport}, @nospecialize(args...))
    BasicPass()(report_type, args...)
end

@testset "JET checks" begin
    rep = report_package("QuantumClifford";
        report_pass=MayThrowIsOk(),
        ignored_modules=(
            AnyFrameModule(Graphs.LinAlg),
            AnyFrameModule(Graphs.SimpleGraphs),
            AnyFrameModule(ArrayInterface),
            AnyFrameModule(Static),
            AnyFrameModule(LinearAlgebra),
            AnyFrameModule(Polyester)
        )
    )
    @show rep
    @test_broken length(JET.get_reports(rep)) == 0 # false positive from https://github.com/aviatesk/JET.jl/issues/444
    @test length(JET.get_reports(rep)) <= 2
end
