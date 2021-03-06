## client.jl - frontend handling command line options, environment setup,
##             and REPL

const text_colors = {
    :black   => "\033[1m\033[30m",
    :red     => "\033[1m\033[31m",
    :green   => "\033[1m\033[32m",
    :yellow  => "\033[1m\033[33m",
    :blue    => "\033[1m\033[34m",
    :magenta => "\033[1m\033[35m",
    :cyan    => "\033[1m\033[36m",
    :white   => "\033[1m\033[37m",
    :normal  => "\033[0m",
    :bold    => "\033[1m",
}

have_color = false
@unix_only default_color_answer = text_colors[:bold]
@unix_only default_color_input = text_colors[:bold]
@windows_only default_color_answer = text_colors[:normal]
@windows_only default_color_input = text_colors[:normal]
color_normal = text_colors[:normal]

function answer_color()
    c = symbol(get(ENV, "JULIA_ANSWER_COLOR", ""))
    return get(text_colors, c, default_color_answer)
end

function input_color()
    c = symbol(get(ENV, "JULIA_INPUT_COLOR", ""))
    return get(text_colors, c, default_color_input)
end

banner() = print(have_color ? banner_color : banner_plain)

exit(n) = ccall(:jl_exit, Void, (Int32,), n)
exit() = exit(0)
quit() = exit()

function repl_callback(ast::ANY, show_value)
    global _repl_enough_stdin = true
    stop_reading(STDIN) 
    STDIN.readcb = false
    put(repl_channel, (ast, show_value))
end

display_error(er) = display_error(er, {})
function display_error(er, bt)
    with_output_color(:red, STDERR) do io
        print(io, "ERROR: ")
        error_show(io, er, bt)
        println(io)
    end
end

function eval_user_input(ast::ANY, show_value)
    errcount, lasterr, bt = 0, (), nothing
    while true
        try
            if have_color
                print(color_normal)
            end
            if errcount > 0
                display_error(lasterr,bt)
                errcount, lasterr = 0, ()
            else
                ast = expand(ast)
                value = eval(Main,ast)
                global ans = value
                if !is(value,nothing) && show_value
                    if have_color
                        print(answer_color())
                    end
                    try repl_show(value)
                    catch err
                        println(STDERR, "Error showing value of type ", typeof(value), ":")
                        rethrow(err)
                    end
                    println()
                end
            end
            break
        catch err
            if errcount > 0
                println(STDERR, "SYSTEM: show(lasterr) caused an error")
            end
            errcount, lasterr = errcount+1, err
            if errcount > 2
                println(STDERR, "WARNING: it is likely that something important is broken, and Julia will not be able to continue normally")
                break
            end
            bt = catch_backtrace()
        end
    end
    println()
end

function readBuffer(stream::AsyncStream, nread)
    global _repl_enough_stdin::Bool
    while !_repl_enough_stdin && nb_available(stream.buffer) > 0
        nread = int(search(stream.buffer,'\n')) # never more than one line or readline explodes :O
        nread2 = int(search(stream.buffer,'\r'))
        if nread == 0
            if nread2 == 0
                nread = nb_available(stream.buffer)
            else
                nread = nread2
            end
        else
            if nread2 != 0 && nread2 < nread
                nread = nread2
            end
        end
        ptr = pointer(stream.buffer.data,stream.buffer.ptr)
        skip(stream.buffer,nread)
        #println(STDERR,stream.buffer.data[stream.buffer.ptr-nread:stream.buffer.ptr-1])
        ccall(:jl_readBuffer,Void,(Ptr{Void},Cssize_t),ptr,nread)
    end
    return false
end

function run_repl()
    global const repl_channel = RemoteRef()

    # install Ctrl-C interrupt handler (InterruptException)
    ccall(:jl_install_sigint_handler, Void, ())
    STDIN.closecb = (x...)->put(repl_channel,(nothing,-1))

    while true
        if have_color
            prompt_string = "\01\033[1m\033[32m\02julia> \01\033[0m"*input_color()*"\02"
        else
            prompt_string = "julia> "
        end
        ccall(:repl_callback_enable, Void, (Ptr{Uint8},), prompt_string)
        global _repl_enough_stdin = false
        start_reading(STDIN, readBuffer)
        (ast, show_value) = take(repl_channel)
        if show_value == -1
            # exit flag
            break
        end
        eval_user_input(ast, show_value!=0)
    end

    if have_color
        print(color_normal)
    end
end

function parse_input_line(s::String)
    # s = bytestring(s)
    # (expr, pos) = parse(s, 1)
    # (ex, pos) = ccall(:jl_parse_string, Any,
    #                   (Ptr{Uint8},Int32,Int32),
    #                   s, int32(pos)-1, 1)
    # if !is(ex,())
    #     throw(ParseError("extra input after end of expression"))
    # end
    # expr
    ccall(:jl_parse_input_line, Any, (Ptr{Uint8},), s)
end

# try to include() a file, ignoring if not found
function try_include(f::String)
    if is_file_readable(f)
        include(f)
    end
end

function process_options(args::Array{Any,1})
    global ARGS, bind_addr
    quiet = false
    repl = true
    startup = true
    color_set = false
    i = 1
    while i <= length(args)
        if args[i]=="-q" || args[i]=="--quiet"
            quiet = true
        elseif args[i]=="--worker"
            start_worker()
            # doesn't return
        elseif args[i]=="--bind-to"
            i += 1
            bind_addr = args[i]
        elseif args[i]=="-e" || args[i]=="--eval"
            repl = false
            i+=1
            ARGS = args[i+1:end]
            eval(Main,parse_input_line(args[i]))
            break
        elseif args[i]=="-E" || args[i]=="--print"
            repl = false
            i+=1
            ARGS = args[i+1:end]
            show(eval(Main,parse_input_line(args[i])))
            println()
            break
        elseif args[i]=="-P" || args[i]=="--post-boot"
            i+=1
            eval(Main,parse_input_line(args[i]))
        elseif args[i]=="-L" || args[i]=="--load"
            i+=1
            require(args[i])
        elseif args[i]=="-p"
            i+=1
            if i > length(args) || !isdigit(args[i][1])
                np = Sys.CPU_CORES
            else
                np = int(args[i])
            end
            addprocs(np-1)
        elseif args[i]=="--machinefile"
            i+=1
            machines = split(readall(args[i]), '\n', false)
            addprocs(machines)
        elseif args[i]=="-v" || args[i]=="--version"
            println("julia version ", VERSION)
            exit(0)
        elseif args[i]=="--no-history"
            # see repl-readline.c
        elseif args[i] == "-f" || args[i] == "--no-startup"
            startup = false
        elseif args[i] == "-F"
            # load juliarc now before processing any more options
            try_include(abspath(ENV["HOME"],".juliarc.jl"))
            startup = false
        elseif beginswith(args[i], "--color")
            if args[i] == "--color"
                color_set = true
                global have_color = true
            elseif args[i][8] == '='
                val = args[i][9:]
                if contains(("no","0","false"), val)
                    color_set = true
                    global have_color = false
                elseif contains(("yes","1","true"), val)
                    color_set = true
                    global have_color = true
                end
            end
            if !color_set
                error("invalid option: ", args[i])
            end
        elseif args[i][1]!='-'
            # program
            repl = false
            # remove julia's arguments
            ARGS = args[i+1:end]
            include(args[i])
            break
        else
            error("unknown option: ", args[i])
        end
        i += 1
    end
    return (quiet,repl,startup,color_set)
end

const roottask = current_task()

is_interactive = false
isinteractive() = (is_interactive::Bool)

function init_load_path()
    vers = "v$(VERSION.major).$(VERSION.minor)"
    global const LOAD_PATH = ByteString[
        abspath(JULIA_HOME,"..","local","share","julia","site",vers),
        abspath(JULIA_HOME,"..","share","julia","site",vers)
    ]
end

function init_sched()
    global const Workqueue = Any[]
    global const Waiting = Dict()
end

function init_head_sched()
    # start in "head node" mode
    global const Scheduler = Task(()->event_loop(true), 1024*1024)
    global PGRP
    global LPROC
    LPROC.id = 1
    assert(length(PGRP.workers) == 0)
    register_worker(LPROC)
    # make scheduler aware of current (root) task
    unshift!(Workqueue, roottask)
    yield()
end

function _start()
    # set up standard streams
    reinit_stdio()
    fdwatcher_reinit()
    # Initialize RNG
    Random.librandom_init()
    # Check that BLAS is correctly built
    check_blas()
    Sys.init()
    global const CPU_CORES = Sys.CPU_CORES

    # set default local address
    global bind_addr = getipaddr()

    @windows_only begin
        user_data_dir = abspath(ENV["AppData"],"julia")
        if !isdir(user_data_dir)
            mkdir(user_data_dir)
        end
        if !haskey(ENV,"HOME")
            ENV["HOME"] = user_data_dir
        end
    end

    #atexit(()->flush(STDOUT))
    try
        init_sched()
        any(a->(a=="--worker"), ARGS) || init_head_sched()
        init_load_path()
        (quiet,repl,startup,color_set) = process_options(ARGS)
        repl && startup && try_include(abspath(ENV["HOME"],".juliarc.jl"))

        if repl
            if isa(STDIN,File)
                global is_interactive = false
                eval(parse_input_line(readall(STDIN)))
                quit()
            end

            if !color_set
                @unix_only global have_color = (beginswith(get(ENV,"TERM",""),"xterm") || success(`tput setaf 0`))
                @windows_only global have_color = true
            end

            global is_interactive = true
            quiet || banner()

            if haskey(ENV,"JL_ANSWER_COLOR")
                warn("JL_ANSWER_COLOR is deprecated, use JULIA_ANSWER_COLOR instead.")
                ENV["JULIA_ANSWER_COLOR"] = ENV["JL_ANSWER_COLOR"]
            end

            run_repl()
        end
    catch err
        display_error(err,catch_backtrace())
        println()
        exit(1)
    end
    if is_interactive
        if have_color
            print(color_normal)
        end
        println()
    end
    ccall(:uv_atexit_hook, Void, ())
end

const atexit_hooks = {}

atexit(f::Function) = (unshift!(atexit_hooks, f); nothing)

function _atexit()
    for f in atexit_hooks
        try
            f()
        catch err
            show(STDERR, err)
            println(STDERR)
        end
    end
end
