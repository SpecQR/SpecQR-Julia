include("protocol.jl")
if "--runtime" in ARGS
    println(S.json_stringify(Dict("julia"=>string(VERSION),"os"=>string(Sys.KERNEL),"arch"=>string(Sys.ARCH),"wordSize"=>Sys.WORD_SIZE,"threads"=>Threads.nthreads())))
    exit()
end
for line in eachline(stdin)
    response=try
        run_request(S.json_parse(line))
    catch e
        e isa InterruptException && rethrow()
        Dict("error"=>string(nameof(typeof(e))),"isSpecQRError"=>e isa S.SpecQRError,"code"=>e isa S.SpecQRError ? S.error_code(e) : "INTERNAL_ERROR","message"=>sprint(showerror,e))
    end
    println(S.json_stringify(response))
end
