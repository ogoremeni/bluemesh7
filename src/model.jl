export generate_positions, initialize_mesh, start, getstats, plotgraph

const ble_37_channel_wavelength = 0.12491352
const part_of_path_loss_for_37 = (ble_37_channel_wavelength / (4 * π))^2

# function agent_step!(source::Source, model::AgentBasedModel)
#     if rand() < model.packet_emit_rate
#         # move off to a random position
#         move_agent!(source, model)

#         # generate next packet
#         source.packet_seq = length(model.packets) + 1
#         source.packet_ttl = model.ttl
#         packet = Packet(source.packet_seq, source.id, rand(1:nagents(model)-1), model.ttl, model.tick, 0, false)
#         push!(model.packets, packet)
#         model.packet_xs[packet.seq] = Int[]

#         source.event_start = model.tick
#     end

#     source.packet_seq == 0 && return
#     model.tick < source.event_start && return

#     d, r = divrem(model.tick - source.event_start, source.t_interpdu)
#     source.transmitting = r == 0
#     source.channel = d + 37

#     if source.channel > 39
#         if source.n_transmit_left > 0
#             source.event_start = model.tick + source.t_og_transmit_delay + rand(source.rt_og_random_delay)
#             source.n_transmit_left -= 1
#             return
#         end

#         # back to resting
#         source.packet_seq = 0
#         source.transmitting = false
#         source.n_transmit_left = source.n_og_transmit_count
#     end
# end
# ■

function randexclude(range::UnitRange{T}, exclude::T) where T
    while true
        x = rand(range)
        x != exclude && return x
    end
end

# ■
function agent_step!(node::Xode, model::AgentBasedModel)
    if rand() < model.packet_emit_rate / model.n
        packet_seq = length(model.packets) + 1
        packet = Packet(packet_seq, node.id, randexclude(1:model.n, node.id), model.ttl, model.tick, 0, false)
        push!(model.packets, packet)
        # @show packet_seq, length(model.packets)
        model.packet_xs[packet.seq] = Int[]
        push!(node.pocket, (model.tick + rand(1:node.t_back_off_delay), packet_seq, model.ttl))
    end

    if node.state == :scanning
        node.channel = div(abs(model.tick - node.event_start), node.t_scan_interval) + 37

        # no packets acquired, repeat scanning
        if node.channel > 39
            node.channel = 37
            node.event_start = model.tick
        end

        # there is no more job for sinks here
        if node.role == :relay && node.packet_seq != 0 && !(node.packet_seq in node.received_packets)
            # println("$(node.packet_seq)--------> $(node.id)")

            push!(node.received_packets, node.packet_seq)

            # for the sake of generality our own packets are treated the same way as others'
            if node.packet_ttl > 1
                # put a packet in the pocket
                push!(node.pocket, (model.tick + rand(1:node.t_back_off_delay), node.packet_seq, node.packet_ttl - 1))
            end
        end
    end

    # @show node.id node.pocket node.state node.channel
    # check for timeout for the first packet in the pocket
    if !isempty(node.pocket) && model.tick >= node.pocket[1][1]
        node.state = :advertising
        node.event_start = model.tick
    end

    if node.state == :advertising
        if model.tick == node.event_start
            _, node.packet_seq, node.packet_ttl = popfirst!(node.pocket)
        end

        d, r = divrem(abs(model.tick - node.event_start), node.t_interpdu)

        # transmitting happens once for each channel
        node.transmitting = iszero(r)
        node.channel = d + 37

        # the end of the advertising
        if node.channel > 39
            # bonus retransmissions for the original/retx packet
            if node.n_transmit_left > 0
                push!(node.pocket, (model.tick + node.t_back_off_delay, node.packet_seq, node.packet_ttl))
            end

            node.packet_seq = 0
            node.transmitting = false
            node.state = :scanning
            node.event_start = model.tick + 1
            node.n_transmit_left = node.n_retx_transmit_count
            node.channel = 37
        end
    end
end

# without sqrt, and taking into account overlapping devices
distance(a::Tuple{Int, Int}, b::Tuple{Int, Int}) = (a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + 1e-3

function xvmap!(arr::SubArray, func::Function)
    length(arr) > 0 || return Array{typeof(func(arr[1])), 1}(undef, 0)
    arr2 = Array{typeof(func(arr[1])), 1}(undef, length(arr))
    @avx for i in 1:length(arr)
        arr2[i] = func(arr[i])
    end
    arr2
end

function calc_rssi!(agents, P_tx::Vector{Float64})
    n = length(agents)
    rssi_map = Matrix{Float64}(undef, n, n)

    L_p = Matrix{Float64}(undef, n, n)

    for i in 1:n
        for j in 1:(i - 1)
            L_p[i, j] = L_p[j, i]
        end

        for j in (i + 1):n
            L_p[i, j] = 1 / distance(agents[i].pos, agents[j].pos)
        end
    end

    @avx for i in 1:n
        for j in 1:n
            rssi_map[i, j] = P_tx[j] * L_p[i, j] * part_of_path_loss_for_37 # dB
        end

        rssi_map[i, i] = 0
    end

    rssi_map
end

# function recalc_sources_rssi!(agents::Vector{Union{Bode, Source}}, rssi_map:: Matrix{Float64}, P_tx::Vector{Float64})
#     n = length(agents)

#     source_i = 1
#     Lps = xvmap!(view(agents, 1:n), x -> 1 / distance(agents[source_i].pos, x.pos))

#     @avx for j in 1:n
#         Lps[j] = Lps[j] * part_of_path_loss_for_37
#         rssi_map[source_i, j] = P_tx[j] * Lps[j] # dB
#     end

#     @avx for j in 1:n
#         rssi_map[j, source_i] = P_tx[source_i] * Lps[j] # dB
#     end

#     rssi_map[source_i, source_i] = 0

#     nothing
# end

function model_step!(model::AgentBasedModel)
    # println(model.tick)
    all_agents = collect(allagents(model))

    transmitters = [
            [a.transmitting && a.channel == 37 for a in all_agents],
            [a.transmitting && a.channel == 38 for a in all_agents],
            [a.transmitting && a.channel == 39 for a in all_agents]
    ]

    transmitters_count = sum(sum(transmitters))
    # transmitters_count > 0 && @show transmitters_count
    count_successes = zeros(Int, nagents(model))

    # (pomdp): clear previous reward nominees
    empty!(model.reward_plate)

    # recalc_sources_rssi!(all_agents, model.rssi_map, model.tx_powers)

    for (dst_i, dst) in enumerate(all_agents)
        dst.state == :scanning || continue

        rssi_neighbours = model.rssi_map[dst_i, transmitters[dst.channel - 36]]

        isempty(rssi_neighbours) && continue

        neighbours_agents = all_agents[transmitters[dst.channel - 36]]

        # add shadow and multipath fading
        # for idx in eachindex(rssi_neighbours)
        #     rssi_neighbours[idx] /= to_mW(rand(model.shadow_d) + rand(model.multipath_d))
        # end

        # register background noise
        total = sum(rssi_neighbours) + 1e-15 # + max(rand(model.wifi_noise_d), 0) + max(rand(model.gaussian_noise), 0)

        # filter unreachable sources
        visible_mask = [rssi > model.scanner_sensitivity for rssi in rssi_neighbours]
        rssi_neighbours = rssi_neighbours[visible_mask]
        neighbours_agents = neighbours_agents[visible_mask]

        isempty(rssi_neighbours) && continue

        message_length = model.msg_bit_length

        # after this step rssi_neighbours become par_neighbours
        for (idx, rssi) in enumerate(rssi_neighbours)
            SINR = rssi / (total - rssi)
            BER = 0.5 * erfc(sqrt(SINR / 2))
            rssi_neighbours[idx] = (1 - BER)^message_length
        end

        total_PAR = sum(rssi_neighbours)

        # do any of this packets pass?
        rand() <= total_PAR || continue

        src_i = sample(1:length(rssi_neighbours), Weights(rssi_neighbours))

        tx_agent = neighbours_agents[src_i]
        packet = model.packets[tx_agent.packet_seq]
        count_successes[tx_agent.id] = 1

        if packet.dst == dst.id
            # since the packet is delivered, acknowledge everyone participating
            !packet.done && append!(model.reward_plate, model.packet_xs[packet.seq])

            # marking the packet as delivered
            packet.done = true
            packet.time_done = model.tick
        else
            # registering the touch upon this yet not delivered packet
            !packet.done && push!(model.packet_xs[packet.seq], dst.id)
            # copying packet's reference
            dst.packet_seq = packet.seq
            dst.packet_ttl = neighbours_agents[src_i].packet_ttl
        end
    end

    if transmitters_count > 0
        model.packets_lost += transmitters_count - sum(count_successes)
        model.transmitters_count += transmitters_count
    end


    model.tick += 1
end


function plotgraph(model::AgentBasedModel)
    g = SimpleGraph(nagents(model))

    for (src_i, src) in enumerate(allagents(model)), (dst_i, dst) in enumerate(allagents(model))
        src.role == :relay || continue
        dst.role != :source || continue

        if model.rssi_map[src_i, dst_i] > model.scanner_sensitivity
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

to_mW(dBm) = 10^(dBm / 10)

"""
    generate_positions(; dims = (200, 200), n = 100) → positions::Array{Tuple{Int,Int},1}

Generates random xy-coordinates for `n` nodes with `dims`
"""
generate_positions(; dims=(100, 100), n=64) = [(rand(1:dims[1]), rand(1:dims[2])) for _ in 1:n]

"""
    initialize_mesh(positions::Vector{Tuple{Int, Int}}, roles::Vector{Int}) → mesh::AgentBasedModel

Create a mesh by specifying roles of each node by `roles`=[0, 1, 0...] where 1 means that the node is a relay, sink otherwise, and including `positions`=[(Int, Int)...] as nodes' positions
"""
function initialize_mesh(positions::Vector{NTuple{2, Int}}, roles::AbstractVector)
    length(roles) == length(positions) || throw(ArgumentError("Both arguments must be of equal length"))
    n = length(roles)

    properties = Dict(
        :n => n,
        :tick => 0,
        :packet_emit_rate => 1 / 1000,
        :packets_lost => 0,
        :transmitters_count => 0,
        :ttl => 5,
        :rssi_map => Matrix{Float64}(undef, n, n),
        :tx_powers => Vector{Float64}(undef, n),
        :scanner_sensitivity => to_mW(-95),
        :msg_bit_length => 312,
        :shadow_d => LogNormal(0, 1),
        :multipath_d => Rayleigh(4),
        :wifi_noise_d => Normal((to_mW(-125) - to_mW(-135)) / 2 + to_mW(-135), (to_mW(-125) - to_mW(-135)) / 2),
        :gaussian_noise => Normal((to_mW(-125) - to_mW(-135)) / 2 + to_mW(-135), (to_mW(-125) - to_mW(-135)) / 2),
        :packets => Packet[],
        # packet.seq => nodes that have touched that packet
        :packet_xs => Dict{Int, Vector{Int}}(),
        # plate for the actors who contributed to packet's successful delivery
        :reward_plate => Int[],
    )

    space = GridSpace((maximum(first.(positions)), maximum(last.(positions))))
    model = ABM(Xode, space; properties, warn = false)

    # source = Source(id = 0, pos = (1, 1))
    # model.tx_powers[1] = source.tx_power
    # add_agent_single!(source, model)

    for i in 1:model.n
        node = Xode(id = i; pos = positions[i], role = roles[i] == 1 ? :relay : :sink)

        add_agent_pos!(node, model)

        model.tx_powers[node.id] = node.tx_power
        model.tx_powers[i] = node.tx_power
    end

    model.rssi_map = calc_rssi!(collect(allagents(model)), model.tx_powers)
    model
end

function getstats(model::AgentBasedModel)
    # filter packets which were too recently produced, or produced in an unreachable position
    filter!(packet -> packet.time_start < model.tick - 500, model.packets)

    # worst case in terms of PDR to a single device
    worstnode = argmax(map(id -> count(p -> p.dst == id && p.done == false, model.packets), 1:nagents(model)-1))
    deprived = filter(p -> p.dst == worstnode, model.packets)
    delivered = filter(p -> p.done == true, model.packets)
    delays = map(p -> p.time_done - p.time_start, delivered)

    # probing centrality measure
    devices = collect(allagents(model))
    filter!(n -> n.role != :source, devices)

    g = SimpleDiGraph(length(devices))

    for (src_i, src) in enumerate(devices), (dst_i, dst) in enumerate(devices)
        src.role == :relay || continue

        if model.rssi_map[src_i, dst_i] > model.scanner_sensitivity
            add_edge!(g, src.id, dst.id)
        end
    end

    centrality = indegree_centrality(g, normalize=false) ./ length(devices) |> mean

    return ( pdr = length(delivered) / length(model.packets),
             worstpdr = count(p -> p.done == true, deprived) / length(deprived),
             delay = mean(delays),
             centrality = centrality,
             packetloss = model.packets_lost / model.transmitters_count)
end

"""
    start(model::AgentBasedModel, minutes = 1) → (received, produced)

Start an experiment from `model` for the given number of minutes.
"""
function start(model::AgentBasedModel; minutes = 1)
    steps = minutes * 60 * 1000
    # steps = 200

    run!(model, agent_step!, model_step!, steps)

    getstats(model)
end
# ■

# ps = generate_positions(dims=(40, 40), n = 64)
# mesh = initialize_mesh(ps, ones(Int, size(ps)))
# mesh = initialize_mesh(ps, rand(0:1, size(ps)))
# mesh.packet_emit_rate = 10 / 1000
# @time start(mesh, minutes = 1)
# plotgraph(mesh)
# mesh.packets
# getstats(mesh)
