using Test, SpecQR
suite = @testset "SpecQR Julia complete" begin
    include("json.jl")
    include("core_segments.jl")
    include("api.jl")
    include("render_gs1.jl")
end
counts = Test.get_test_counts(suite)
# Julia 1.10 returns a positional tuple; Julia 1.13 returns TestCounts.
if counts isa Tuple
    passes, fails, errors, broken = ntuple(i -> counts[i] + counts[i + 4], 4)
else
    passes = counts.passes + counts.cumulative_passes
    fails = counts.fails + counts.cumulative_fails
    errors = counts.errors + counts.cumulative_errors
    broken = counts.broken + counts.cumulative_broken
end
println("SPECQR_TESTS_JSON=" * SpecQR.json_stringify(Dict(
    "status" => "passed", "checks" => passes, "failed" => fails,
    "errored" => errors, "broken" => broken,
    "julia" => string(VERSION), "threads" => Threads.nthreads())))
