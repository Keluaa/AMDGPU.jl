
mutable struct HSAKernelInstance{T<:Tuple}
    agent::HSAAgent
    exe::HSAExecutable
    sym::String
    args::T
    # FIXME: Stop being lazy and put in some damn types!
    kernel_object
    kernarg_segment_size
    group_segment_size
    private_segment_size
    kernarg_address::Ref{Ptr{Nothing}}
end

# TODO agent can be inferred from the executable
function HSAKernelInstance(agent::HSAAgent, exe::HSAExecutable, symbol::String, args::Tuple)
    agent_func = @cfunction(iterate_exec_agent_syms_cb, HSA.Status,
                           (HSA.Executable, HSA.Agent, HSA.ExecutableSymbol, Ptr{Cvoid}))
    exec_symbol = Ref{HSA.ExecutableSymbol}()
    exec_ptr = Base.unsafe_convert(Ref{Cvoid}, exec_symbol)
    @debug "Agent symbols"
    HSA.executable_iterate_agent_symbols(exe.executable[], agent.agent,
                                         agent_func, exec_ptr) |> check

    # TODO: Conditionally disable once ROCR is fixed
    if !isassigned(exec_symbol)
        agent_ref = Ref(agent.agent)
        GC.@preserve agent_ref begin
            HSA.executable_get_symbol_by_name(exe.executable[], symbol,
                                              agent_ref, exec_symbol) |> check
        end
    end

    kernel_object = Ref{UInt64}(0)
    getinfo(exec_symbol[], HSA.EXECUTABLE_SYMBOL_INFO_KERNEL_OBJECT,
            kernel_object) |> check

    kernarg_segment_size = Ref{UInt32}(0)
    getinfo(exec_symbol[], HSA.EXECUTABLE_SYMBOL_INFO_KERNEL_KERNARG_SEGMENT_SIZE,
            kernarg_segment_size) |> check

    if kernarg_segment_size[] == 0
        # FIXME: Hidden arguments!
        kernarg_segment_size[] = sum(sizeof.(args))
    end

    group_segment_size = Ref{UInt32}(0)
    getinfo(exec_symbol[], HSA.EXECUTABLE_SYMBOL_INFO_KERNEL_GROUP_SEGMENT_SIZE,
            group_segment_size) |> check

    private_segment_size = Ref{UInt32}(0)
    getinfo(exec_symbol[], HSA.EXECUTABLE_SYMBOL_INFO_KERNEL_PRIVATE_SEGMENT_SIZE,
            private_segment_size) |> check

    finegrained_region = get_region(agent, :finegrained)
    kernarg_region = get_region(agent, :kernarg)

    # Allocate the kernel argument buffer from the correct region
    kernarg_address = Ref{Ptr{Nothing}}()
    HSA.memory_allocate(kernarg_region[],
                        kernarg_segment_size[],
                        kernarg_address) |> check
    ctr = 0x0

    for arg in args
        rarg = Ref(arg)
        ccall(:memcpy, Cvoid,
            (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t),
            kernarg_address[]+ctr, rarg, sizeof(arg))
        ctr += sizeof(arg)
    end

    kernel = HSAKernelInstance(agent, exe, symbol, args, kernel_object,
                               kernarg_segment_size, group_segment_size,
                               private_segment_size, kernarg_address)
    hsaref!()
    finalizer(kernel) do kernel
        HSA.memory_free(kernel.kernarg_address[]) |> check
        hsaunref!()
    end
    return kernel
end

# TODO Docstring
function launch!(queue::HSAQueue, kernel::HSAKernelInstance, signal::HSASignal;
                 workgroup_size=nothing, grid_size=nothing)
    @assert workgroup_size !== nothing "Must specify workgroup_size kwarg"
    @assert grid_size !== nothing "Must specify grid_size kwarg"

    agent = queue.agent
    queue = queue.queue
    signal = signal.signal
    args = kernel.args

    # Obtain the current queue write index and queue size
    _queue_size = Ref{UInt32}(0)
    getinfo(agent.agent, HSA.AGENT_INFO_QUEUE_MAX_SIZE, _queue_size) |> check
    queue_size = _queue_size[]
    write_index = HSA.queue_add_write_index_scacq_screl(queue[], UInt64(1))

    # Yield until queue has space
    while true
        read_index = HSA.queue_load_read_index_scacquire(queue[])
        if write_index < read_index + queue_size
            break
        end
        yield()
    end

    # TODO: Make this less ugly
    dispatch_packet = Ref{HSA.KernelDispatchPacket}()
    ccall(:memset, Cvoid,
        (Ptr{Cvoid}, Cint, Csize_t),
        dispatch_packet, 0, sizeof(dispatch_packet[]))
    _packet = dispatch_packet[]
    @set! _packet.setup = 0
    @set! _packet.setup |= 3 << Int(HSA.KERNEL_DISPATCH_PACKET_SETUP_DIMENSIONS)
    @set! _packet.workgroup_size_x = workgroup_size[1]
    @set! _packet.workgroup_size_y = workgroup_size[2]
    @set! _packet.workgroup_size_z = workgroup_size[3]
    @set! _packet.grid_size_x = grid_size[1]
    @set! _packet.grid_size_y = grid_size[2]
    @set! _packet.grid_size_z = grid_size[3]
    @set! _packet.completion_signal = signal[]
    @set! _packet.kernel_object = kernel.kernel_object[]
    @set! _packet.kernarg_address = kernel.kernarg_address[]
    @set! _packet.private_segment_size = kernel.private_segment_size[]
    @set! _packet.group_segment_size = kernel.group_segment_size[]
    dispatch_packet = Ref{HSA.KernelDispatchPacket}(_packet)

    _queue = unsafe_load(queue[])
    queueMask = UInt32(_queue.size - 1)
    baseaddr_ptr = Ptr{HSA.KernelDispatchPacket}(_queue.base_address)
    baseaddr_ptr += sizeof(HSA.KernelDispatchPacket) * (write_index & queueMask)
    dispatch_packet_ptr = Base.unsafe_convert(Ptr{HSA.KernelDispatchPacket}, dispatch_packet)
    unsafe_copyto!(baseaddr_ptr, dispatch_packet_ptr, 1)

    # Atomically store the header
    header = Ref{UInt16}(0)
    header[] |= Int(HSA.FENCE_SCOPE_SYSTEM) << Int(HSA.PACKET_HEADER_ACQUIRE_FENCE_SCOPE)
    header[] |= Int(HSA.FENCE_SCOPE_SYSTEM) << Int(HSA.PACKET_HEADER_RELEASE_FENCE_SCOPE)
    header[] |= Int(HSA.PACKET_TYPE_KERNEL_DISPATCH) << Int(HSA.PACKET_HEADER_TYPE)
    atomic_store_n!(Base.unsafe_convert(Ptr{UInt16}, baseaddr_ptr), header[])

    # Ring the doorbell to dispatch the kernel
    HSA.signal_store_relaxed(_queue.doorbell_signal, Int64(write_index))
end

