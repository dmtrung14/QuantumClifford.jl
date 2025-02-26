"""
$(TYPEDEF)

This is a wrapper around a tableau. This "frame" tableau is not to be viewed as a normal stabilizer tableau,
although it does conjugate the same under Clifford operations.
Each row in the tableau refers to a single frame.
The row represents the Pauli operation by which the frame and the reference differ.
"""
struct PauliFrame{T,S} <: AbstractQCState
    frame::T # TODO this should really be a Tableau, but now most of the code seems to be assuming a Stabilizer
    measurements::S # TODO check if when looping over this we are actually looping over the fast axis
end

nqubits(f::PauliFrame) = nqubits(f.frame)
Base.length(f::PauliFrame) = size(f.measurements, 1)
Base.eachindex(f::PauliFrame) = 1:length(f)
Base.copy(f::PauliFrame) = PauliFrame(copy(f.frame), copy(f.measurements))
Base.view(frame::PauliFrame, r) = PauliFrame(view(frame.frame, r), view(frame.measurements, r, :))

"""
$(TYPEDSIGNATURES)

Prepare an empty set of Pauli frames with the given number of `frames` and `qubits`. Preallocates spaces for `measurement` number of measurements.
"""
function PauliFrame(frames, qubits, measurements)
    stab = zero(Stabilizer, frames, qubits) # TODO this should really be a Tableau
    frame = PauliFrame(stab, zeros(Bool, frames, measurements))
    initZ!(frame)
    return frame
end

"""
$(TYPEDSIGNATURES)

Inject random Z errors over all frames and qubits for the supplied PauliFrame with probability 0.5.

Calling this after initialization is essential for simulating any non-deterministic circuit.
It is done automatically by most [`PauliFrame`](@ref) constructors.
"""
function initZ!(frame::PauliFrame)
    T = eltype(frame.frame.tab.xzs)

    @inbounds @simd for f in eachindex(frame) # TODO thread this
        @simd for row in 1:size(frame.frame.tab.xzs,1)÷2
            frame.frame.tab.xzs[end÷2+row,f] = rand(T)
        end
    end
    return frame
end

function apply!(f::PauliFrame, op::AbstractCliffordOperator)
    _apply!(f.frame, op; phases=Val(false))
    return f
end

function apply!(frame::PauliFrame, op::sMZ) # TODO sMX, sMY
    op.bit == 0 && return frame
    i = op.qubit
    xzs = frame.frame.tab.xzs
    T = eltype(xzs)
    lowbit = T(1)
    ibig = _div(T,i-1)+1
    ismall = _mod(T,i-1)
    ismallm = lowbit<<(ismall)

    @inbounds @simd for f in eachindex(frame) # TODO thread this
        should_flip = !iszero(xzs[ibig,f] & ismallm)
        frame.measurements[f,op.bit] = should_flip
    end

    return frame
end

function apply!(frame::PauliFrame, op::sMRZ) # TODO sMRX, sMRY
    i = op.qubit
    xzs = frame.frame.tab.xzs
    T = eltype(xzs)
    lowbit = T(1)
    ibig = _div(T,i-1)+1
    ismall = _mod(T,i-1)
    ismallm = lowbit<<(ismall)

    if op.bit != 0
        @inbounds @simd for f in eachindex(frame) # TODO thread this
            should_flip = !iszero(xzs[ibig,f] & ismallm)
            frame.measurements[f,op.bit] = should_flip
        end
    end
    @inbounds @simd for f in eachindex(frame) # TODO thread this
        xzs[ibig,f] &= ~ismallm
        rand(Bool) && (xzs[end÷2+ibig,f] ⊻= ismallm)
    end

    return frame
end

function applynoise!(frame::PauliFrame,noise::UnbiasedUncorrelatedNoise,i::Int)
    p = noise.errprobthird
    T = eltype(frame.frame.tab.xzs)

    lowbit = T(1)
    ibig = _div(T,i-1)+1
    ismall = _mod(T,i-1)
    ismallm = lowbit<<(ismall)

    @inbounds @simd for f in eachindex(frame) # TODO thread this
        r = rand()
        if  r < p # X error
            frame.frame.tab.xzs[ibig,f] ⊻= ismallm
        elseif r < 2p # Z error
            frame.frame.tab.xzs[end÷2+ibig,f] ⊻= ismallm
        elseif r < 3p # Y error
            frame.frame.tab.xzs[ibig,f] ⊻= ismallm
            frame.frame.tab.xzs[end÷2+ibig,f] ⊻= ismallm
        end
    end
    return frame
end

"""
Perform a "Pauli frame" style simulation of a quantum circuit.
"""
function pftrajectories end

"""
$(TYPEDSIGNATURES)

The main method for running Pauli frame simulations of circuits.
See the other methods for lower level access.

Multithreading is enabled by default, but can be disabled by setting `threads=false`.
Do not forget to launch Julia with multiple threads enabled, e.g. `julia -t4`, if you want
to use multithreading.

Note for advanced users: Much of the underlying QuantumClifford.jl functionaly is capable of
using Polyester.jl threads, but they are fully dissabled here as this is an embarassingly
parallel problem. If you want to use Polyester.jl threads, use the lower level methods.
The `threads` keyword argument controls whether standard Julia threads are used.
"""
function pftrajectories(circuit;trajectories=5000,threads=true)
    Polyester.disable_polyester_threads() do
        _pftrajectories(circuit;trajectories,threads)
    end
end

function _pftrajectories(circuit;trajectories=5000,threads=true)
    ccircuit = if eltype(circuit) <: CompactifiedGate
        circuit
    else
        compactify_circuit(circuit)
    end
    qmax=maximum((maximum(affectedqubits(g)) for g in ccircuit))
    bmax=maximum((maximum(affectedbits(g),init=1) for g in ccircuit))
    frames = PauliFrame(trajectories, qmax, bmax)
    nthr = min(Threads.nthreads(),trajectories÷(MINBATCH1Q))
    if threads && nthr>1
        batchsize = trajectories÷nthr
        Threads.@threads for i in 1:nthr
            b = (i-1)*batchsize+1
            e = i==nthr ? trajectories : i*batchsize
            pftrajectories((@view frames[b:e]), ccircuit)
        end
    else
        pftrajectories(frames, ccircuit)
    end
    return frames
end

"""
$(TYPEDSIGNATURES)

Evolve each frame stored in [`PauliFrame`](@ref) by the given circuit.
"""
function pftrajectories(state::PauliFrame, circuit)
    for op in circuit
        apply!(state, op)
    end
    return state
end

"""
$(TYPEDSIGNATURES)

For a given [`Register`](@ref) and circuit, simulates the reference circuit acting on the
register and then also simulate numerous [`PauliFrame`](@ref) trajectories.
Returns the register and the [`PauliFrame`](@ref) instance.

Use [`pfmeasurements`](@ref) to get the measurement results.
"""
function pftrajectories(register::Register, circuit; trajectories=500)
    for op in circuit
        apply!(register, op)
    end
    frame = PauliFrame(trajectories, nqubits(register), length(bitview(register)))
    pftrajectories(frame, circuit)
    register, frame
end

"""
For a given simulated state, e.g. a [`PauliFrame`](@ref) instance, returns the measurement results.
"""
function pfmeasurement end

"""
$(TYPEDSIGNATURES)

Returns the measurements stored in the bits of the given [`Register`](@ref).
"""
pfmeasurements(register::Register) = bitview(register)

"""
$(TYPEDSIGNATURES)

Returns the measurement results for each frame in the [`PauliFrame`](@ref) instance.

!!! warning "Relative mesurements"
    The return measurements are relative to the reference measurements, i.e. they only say
    whether the reference measurements have been flipped in the given frame.
"""
pfmeasurements(frame::PauliFrame) = frame.measurements

"""
$(TYPEDSIGNATURES)

Takes the references measurements from the given [`Register`](@ref) and applies the flips
as prescribed by the [`PauliFrame`](@ref) relative measurements. The result is the actual
(non-relative) measurement results for each frame.
"""
pfmeasurements(register::Register, frame::PauliFrame) = pfmeasurements(register) .⊻ pfmeasurements(frame)
