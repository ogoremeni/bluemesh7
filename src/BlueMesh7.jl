module BlueMesh7
using Agents, AgentsPlots
using LightGraphs, GraphPlot
using Random
using DataStructures: CircularBuffer

export generate_graph, initialize_mesh, run, plotgraph, start

mutable struct Packet
    seq :: Int
    src :: UInt16
    dst :: UInt16
    ttl :: UInt8

    time_start :: Int
    time_done :: Int
    done :: Bool
end

Base.@kwdef mutable struct Node <: AbstractAgent
    id::Int

    # (x, y) coordinates
    pos :: Tuple{Int, Int}

    # role = :relay | :sink
    role :: Symbol

    # channel = 37 | 38 | 39
    channel :: UInt8 = 37

    # state = :scanning | :advertising | :sleeping
    state :: Symbol = :scanning

    # the time of the event's (current state) begging
    event_start :: Int = rand(0:50)

    # whether the device is currently sending data (this removes the need for redundant allocations)
    transmitting :: Bool = false

    # the power of the transmission
    dBm :: Int = 4

    # the length of the interval between transmissions on different channels (ms)
    t_interpdu :: UInt = 5

    # the length of the interval between scanning on different channels (ms)
    t_scan_interval :: UInt = 20

    # the length of the interval before advertising the received packet
    t_back_off_delay :: UInt = 5

    # the number of extra retransmissions of the received packet
    n_retx_transmit_count :: UInt = 0

    # the length of the delay between bonus transmissions of the received packet (ms)
    t_retx_transmit_delay :: UInt = 20

    # additional random component of delay between retransmissions (min:max ms)
    rt_retx_random_delay :: UnitRange{Int} = 20:50

    # the current number of extra transmissions left
    n_transmit_left :: UInt = 0

    # buffer containing seq of the received packets
    received_packets :: CircularBuffer{Int} = CircularBuffer{Int}(20)

    # the reference to the current holding packet
    packet_seq :: Int = 0

    # own ttl for the current packet
    packet_ttl :: UInt8 = 0
end

Base.@kwdef mutable struct Source <: AbstractAgent
    id :: Int
    pos :: Tuple{Int, Int}

    role :: Symbol = :source
    state :: Symbol = :advertising

    channel :: UInt8 = 37
    event_start :: UInt = 0
    dBm :: Int = 4
    transmitting :: Bool = false

    t_interpdu :: UInt = 5

    # the number of extra transmissions of the packet originating from the node
    n_og_transmit_count :: UInt = 2

    # the length of the delay between additional transmissions of the original packet (ms)
    t_og_transmit_delay :: UInt = 20

    # the range of the additional random component to delay between additional original transmissions
    rt_og_random_delay :: UnitRange{Int} = 0:20

    # the current number of extra transmissions left
    n_transmit_left :: UInt = 0

    packet_seq :: Int = 0
    packet_ttl :: Int = 0
end

function agent_step!(source::Source, model::AgentBasedModel)
    if rand() < model.packet_emit_rate
        # move off to a random position
        move_agent!(source, model)

        # generate next packet
        source.packet_seq = length(model.packets) + 1
        source.packet_ttl = model.ttl
        packet = Packet(source.packet_seq, source.id, rand(1:nagents(model)-1), model.ttl, model.tick, 0, false)
        push!(model.packets, packet)
        model.packet_xs[packet.seq] = Int[]

        source.event_start = model.tick
    end

    source.packet_seq == 0 && return
    model.tick < source.event_start && return

    d, r = divrem(model.tick - source.event_start, source.t_interpdu)
    source.transmitting = r == 0
    source.channel = d + 37

    if source.channel > 39
        if source.n_transmit_left > 0
            source.event_start = model.tick + source.t_og_transmit_delay + rand(source.rt_og_random_delay)
            source.n_transmit_left -= 1

            return
        end

        # back to resting
        source.packet_seq = 0
        source.transmitting = false
        source.n_transmit_left = source.n_og_transmit_count
    end
end

function agent_step!(node::Node, model::AgentBasedModel)
    if node.state == :scanning
        # scanning happens every tick (assuming here scan_window == scan_interval)
        node.channel = div(abs(model.tick - node.event_start), node.t_scan_interval) + 37

        # no packets acquired, repeat scanning
        if node.channel > 39
            node.channel = 37
            node.event_start = model.tick
        end

        node.packet_seq == 0 && return

        # we've seen this seq recently
        if node.packet_seq in node.received_packets
            node.packet_seq = 0
            return
        end

        push!(node.received_packets, node.packet_seq)

        packet = model.packets[node.packet_seq]

        # the delivery is processed in model_step!, here's just for completness
        if packet.dst == node.id
            node.packet_seq = 0
            println("this never?")
            return
        end

        if node.packet_ttl == 1
            node.packet_seq = 0
            return
        end



        node.packet_ttl -= 1

        if node.role == :relay
            # initiating back-off delay before advertising this packet
            node.event_start = model.tick + node.t_back_off_delay
            node.state = :advertising
            return
        end
    end

    node.role != :relay && return

    if node.state == :advertising
        model.tick < node.event_start && return

        # return to scanning if the packet is absent
        if node.packet_seq == 0
            node.state = :scanning
            node.event_start = model.tick
            return
        end

        d, r = divrem(abs(model.tick - node.event_start), node.t_interpdu)

        # transmitting happens once for each channel
        node.transmitting = iszero(r)
        # if node.transmitting
        #     println("$(node.id) broadcasting $(node.packet.seq)")
        # end

        node.channel = d + 37

        # the end of the advertising
        if node.channel > 39
            # bonus retransmissions for the original/retx packet
            if node.n_transmit_left > 0
                node.event_start = model.tick + node.t_retx_transmit_delay + rand(node.rt_retx_random_delay)

                node.n_transmit_left -= 1
                return
            end

            node.packet_seq = 0
            node.transmitting = false
            node.state = :scanning
            node.event_start = model.tick + 1
            node.n_transmit_left = node.n_retx_transmit_count
        end
    end
end

power_to_distance(dBm::Int) = exp(dBm)
distance(a::Tuple{Int, Int}, b::Tuple{Int, Int}) = sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2)

function model_step!(model::AgentBasedModel)
    transmitters = filter(agent -> agent.transmitting, collect(allagents(model)))

    empty!(model.reward_plate)

    for dst in allagents(model)
        dst.state == :scanning || continue

        neighbours = filter(src -> distance(src.pos, dst.pos) < power_to_distance(src.dBm) && src.channel == dst.channel, transmitters)
        length(neighbours) != 1 && continue

        rand() < model.packet_error_rate && continue

        packet = model.packets[first(neighbours).packet_seq]

        packet.done && continue
        # registering the touch upon this yet not delivered packet
        push!(model.packet_xs[packet.seq], dst.id)

        # this is mainly for the pomdp interface
        if packet.dst == dst.id
            # since the packet is delivered, acknowledge everyone participating
            append!(model.reward_plate, model.packet_xs[packet.seq])
        end

        # marking the packet as delivered
        if packet.dst == dst.id
            packet.done = true
            packet.time_done = model.tick

            continue
        end

        # copying packet's reference
        dst.packet_seq = packet.seq
        dst.packet_ttl = first(neighbours).packet_ttl
    end

    model.tick += 1
end


function plotgraph(model::AgentBasedModel)
    g = SimpleGraph(nagents(model) - 1)

    for src in allagents(model), dst in allagents(model)
        src.role == :relay || continue
        dst.role != :source || continue

        if distance(src.pos, dst.pos) <= power_to_distance(src.dBm)
            add_edge!(g, src.id, dst.id)
        end
    end

    colors = Dict(:relay => "orange", :sink => "darkblue", :source => "transparent")

    agents = sort(collect(allagents(model)), by=a -> a.id)
    filter!(a -> a.role != :source, agents)
    xs = map(a -> a.pos[1], agents)
    ys = map(a -> a.pos[2], agents)
    cs = map(a -> colors[a.role], agents)

    gplot(g, xs, ys; nodefillc = cs)
end

"""
    generate_graph(; dims = (200, 200), n_nodes = 100) → adjacency, positions

Generates a random graph and returns the adjacency matrix and xy-coordinates of the nodes
"""
function generate_graph(; dims = (100, 100), n_nodes = 64)
    positions = [(rand(1:dims[1]), rand(1:dims[2])) for _ in 1:n_nodes]
    g = SimpleGraph(n_nodes)

    for src in 1:n_nodes, dst in src+1:n_nodes
        if distance(positions[src], positions[dst]) <= exp(4)
            add_edge!(g, src, dst)
        end
    end

    positions, Matrix(adjacency_matrix(g))
end

"""
    initialize_mesh(positions::Vector{Tuple{Int, Int}}, roles::Vector{Int}) → mesh::AgentBasedModel

Create a mesh by specifying roles of each node by `roles`=[0, 1, 0...] where 1 means that the node is a relay, sink otherwise, and including `positions`=[(Int, Int)...] as nodes' positions
"""
function initialize_mesh(positions::Vector{Tuple{Int, Int}}, roles::Vector{Int})
    length(roles) == length(positions) || throw(ArgumentError("Both arguments must be of equal length"))

    properties = Dict(
        :tick => 0,
        :packet_error_rate => 0.05,
        :packet_emit_rate => 10 / 1000,
        :ttl => 4,
        :packets => Packet[],
        # packet.seq => nodes that have touched that packet
        :packet_xs => Dict{Int, Vector{Int}}(),
        # plate for the actors who contributed to packet's successful delivery
        :reward_plate => Int[]
    )

    space = GridSpace((maximum(first.(positions)), maximum(last.(positions))))
    model = ABM(Union{Source, Node}, space; properties, warn = false)

    for (pos, roles_i) in zip(positions, roles)
        node = Node(id = nextid(model); pos, role = roles_i == 1 ? :relay : :sink)

        add_agent_pos!(node, model)
    end

    add_agent_single!(Source(id = 0, pos = (1, 1)), model)

    model
end

"""
    start(model::AgentBasedModel, minutes = 1) → (received, produced)

Start an experiment from `model` for the given number of minutes.
"""
function start(model::AgentBasedModel; minutes = 1)
    steps = minutes * 60 * 1000

    _, dfm = run!(model, agent_step!, model_step!, steps)

    # filter packets which were too recently produced, or produced in an unreachable position
    filter!(packet -> packet.time_start < steps - 5000 && !isempty(model.packet_xs[packet.seq]), model.packets)

    # worst case in terms of PDR to a single device
    worstnode = argmax(map(id -> count(p -> p.dst == id && p.done == false, model.packets), 1:nagents(model)-1))
    deprived = filter(p -> p.dst == worstnode, model.packets)
    delivered = filter(p -> p.done == true, model.packets)
    delays = map(p -> p.time_done - p.time_start, delivered)

    return ( PDR = length(delivered) / length(model.packets),
             worstPDR = count(p -> p.done == false, deprived) / length(deprived),
             delay = sum(delays) / length(delays) )
end
end
