function allocate_tree_if_necessary(tree::Octree)
    if tree.nextfreenode >= length(tree.treenodes) - 8
        if length(tree.treenodes) <= tree.config.MaxTreenode
            append!(tree.treenodes, [OctreeNode(tree.units) for i in 1:tree.config.TreeAllocSection])
        else
            error("Running out of tree nodes in creating empty nodes, please increase MaxTreenode in Config")
        end
    end
end

function create_empty_treenodes(tree::Octree, no::Int64, top::Int64, bits::Int64, x::Int64, y::Int64, z::Int64)
    topnodes = tree.domain.topnodes
    treenodes = tree.treenodes

    allocate_tree_if_necessary(tree)

    if topnodes[top].Daughter >= 0
        for i = 0:1
            for j = 0:1
                for k = 0:1
                    sub = Int64(7 & peanokey((x << 1) + i, (y << 1) + j, (z << 1) + k, bits = bits))
                    count = 1 + i + 2 * j + 4 * k

                    treenodes[no].DaughterID[count] = tree.nextfreenode
                    treenodes[tree.nextfreenode] = setproperties!!(treenodes[tree.nextfreenode], SideLength = 0.5 * treenodes[no].SideLength,
                                                       Center = treenodes[no].Center + PVector((2 * i - 1) * 0.25 * treenodes[no].SideLength,
                                                                                               (2 * j - 1) * 0.25 * treenodes[no].SideLength,
                                                                                               (2 * k - 1) * 0.25 * treenodes[no].SideLength))

                    if topnodes[topnodes[top].Daughter + sub].Daughter == -1
                        # this table gives for each leaf of the top-level tree the corresponding node of the gravitational tree
                        tree.domain.DomainNodeIndex[topnodes[topnodes[top].Daughter + sub].Leaf] = tree.nextfreenode
                    end

                    tree.NTreenodes += 1
                    tree.nextfreenode += 1

                    create_empty_treenodes(tree,
                                            tree.nextfreenode - 1, tree.domain.topnodes[top].Daughter + sub,
                                            bits + 1, 2 * x + i, 2 * y + j, 2 * z + k)
                end
            end
        end
    end
end

function init_treenodes(tree::Octree)
    tree.domain.DomainNodeIndex = zeros(Int64, tree.domain.NTopLeaves)

    tree.treenodes = [OctreeNode(tree.units) for i in 1:tree.config.TreeAllocSection]
    tree.treenodes[1] = setproperties!!(tree.treenodes[1], Center = tree.extent.Center,
                                                           SideLength = tree.extent.SideLength)

    tree.NTreenodes = 1
    tree.nextfreenode = 2

    create_empty_treenodes(tree, 1, 1, 1, 0, 0, 0)
end

function find_subnode(Pos::PVector, Center::PVector)
    subnode = 1
    if Pos.x > Center.x
        subnode += 1
    end
    if Pos.y > Center.y
        subnode += 2
    end
    if Pos.z > Center.z
        subnode += 4
    end
    return subnode
end

find_subnode(p::AbstractParticle, Center::AbstractPoint) = find_subnode(p.Pos, Center)

function check_inbox(Pos::PVector, Center::PVector, SideLength::Number)
    half_len = SideLength * 0.5
    if Pos.x < Center.x - half_len || Pos.x > Center.x + half_len ||
        Pos.y < Center.y - half_len || Pos.y > Center.y + half_len ||
        Pos.z < Center.z - half_len || Pos.z > Center.z + half_len
        return false
    end
    return true
end

function isclosepoints(len::Quantity, u::Units, threshold::Float64)
    if ustrip(u, len) < threshold
        return true
    else
        return false
    end
end

function isclosepoints(len::Float64, ::Nothing, threshold::Float64)
    if len < threshold
        return true
    else
        return false
    end
end

function assign_new_tree_leaf(tree::Octree, index::Int, parent::Int, subnode::Int)
    treenodes = tree.treenodes
    epsilon = tree.config.epsilon
    uLength = getuLength(tree.units)

    treenodes[parent].DaughterID[subnode] = tree.nextfreenode

    MassOld = treenodes[parent].Mass
    MassCenterOld = treenodes[parent].MassCenter
    treenodes[parent] = setproperties!!(treenodes[parent], IsAssigned = false,
                                                           Mass = MassOld * 0.0,
                                                           MassCenter = MassCenterOld * 0.0)

    treenodes[tree.nextfreenode] = setproperties!!(treenodes[tree.nextfreenode] , SideLength = 0.5 * treenodes[parent].SideLength)
    lenhalf = 0.25 * treenodes[parent].SideLength

    if (subnode - 1) & 1 > 0
        centerX = treenodes[parent].Center.x + lenhalf
    else
        centerX = treenodes[parent].Center.x - lenhalf
    end

    if (subnode - 1) & 2 > 0
        centerY = treenodes[parent].Center.y + lenhalf
    else
        centerY = treenodes[parent].Center.y - lenhalf
    end

    if (subnode - 1) & 4 > 0
        centerZ = treenodes[parent].Center.z + lenhalf
    else
        centerZ = treenodes[parent].Center.z - lenhalf
    end

    # copy the old particle data
    treenodes[tree.nextfreenode] = setproperties!!(treenodes[tree.nextfreenode], IsAssigned = true,
                                                                                 Center = PVector(centerX, centerY, centerZ),
                                                                                 Mass = MassOld,
                                                                                 MassCenter = MassCenterOld)


    # Resume trying to insert the new particle at the newly created internal node
    index = tree.nextfreenode

    tree.NTreenodes += 1
    tree.nextfreenode += 1

    allocate_tree_if_necessary(tree)

    return index
end

function assign_data_to_tree_leaf(tree::Octree, index::Int, p::AbstractParticle)
    tree.treenodes[index] = setproperties!!(tree.treenodes[index], Mass = p.Mass,
                                                                   MassCenter = p.Pos,
                                                                   IsAssigned = true)
end

function assign_data_to_tree_leaf(tree::Octree, index::Int, p::AbstractPoint)
    tree.treenodes[index] = setproperties!!(tree.treenodes[index], MassCenter = p, IsAssigned = true)
end

function insert_data(tree::Octree)
    DomainCorner = tree.extent.Corner
    data = tree.data
    topnodes = tree.domain.topnodes
    treenodes = tree.treenodes
    epsilon = tree.config.epsilon
    uLength = getuLength(tree.units)
    for p in Iterators.flatten(values(data))
        key = peanokey(p, DomainCorner, tree.domain.DomainFac)

        no = 1
        while topnodes[no].Daughter >= 0
            @inbounds no = trunc(Int64, topnodes[no].Daughter + div((key - topnodes[no].StartKey) , div(topnodes[no].Size , 8)))
        end
        no = topnodes[no].Leaf
        index = tree.domain.DomainNodeIndex[no]

        subnode = 0
        parent = -1
        while true
            #! Assigned nodes do not have internal daughter leaves
            if !treenodes[index].IsAssigned
                # Internal node
                subnode = find_subnode(p, treenodes[index].Center)
                nn = treenodes[index].DaughterID[subnode]

                if nn > 0 # branch node
                    parent = index
                    index = nn
                else
                    # version 1 - here we have found an empty slot where we can attach the new particle as a leaf
                    # version 2 - we copy information of the particle to this leaf node
                    assign_data_to_tree_leaf(tree, index, p)

                    break
                end
                # in the next loop, the particle will be settled
            else
                # We try to insert into a leaf witch already has been assigned with a particle
                # Need to generate a new internal node at this point
                index = assign_new_tree_leaf(tree, index, parent, subnode)

                subnode = find_subnode(tree.data[index], treenodes[tree.nextfreenode].Center)

                if isclosepoints(treenodes[tree.nextfreenode].SideLength, uLength, 1.0e-3 * epsilon)
                    subnode = trunc(Int64, 8.0 * rand()) + 1
                    #p.GravCost += 1
                    if subnode >= 9
                        subnode = 8
                    end
                end
            end
        end
    end
end

function insert_data_pseudo(tree::Octree)
    tree.domain.DomainMoment = [DomainNode(tree.units) for i in 1:tree.domain.NTopLeaves]

    MaxTreenode = tree.config.MaxTreenode
    treenodes = tree.treenodes
    for i in 1:tree.domain.NTopLeaves
        @inbounds tree.domain.DomainMoment[i] = setproperties!!(tree.domain.DomainMoment[i], Mass = 0.0 * tree.domain.DomainMoment[i].Mass,
                                                                    MassCenter = treenodes[tree.domain.DomainNodeIndex[i]].Center)
    end

    for i in 1:tree.domain.NTopLeaves
        if i < tree.domain.DomainMyStart || i > tree.domain.DomainMyEnd
            index = 1

            while true
                if index > 0
                    if index > MaxTreenode
                        @show index
                        error("Error in DomainMoment indexing #01")
                    end

                    subnode = find_subnode(tree.domain.DomainMoment[i].MassCenter, treenodes[index].Center)
                    nn = treenodes[index].DaughterID[subnode]

                    if nn > 0
                        index = nn
                    else
                        # here we have found an empty slot where we can attach the pseudo particle as a leaf
                        #! Assigned nodes could have pseudo leaves
                        treenodes[index].DaughterID[subnode] = MaxTreenode + i
                        break
                    end
                else
                    @show index
                    error("Error in DomainMoment indexing #02, index = ", index)
                end
            end
        end
    end
end

function build(tree::Octree)
    bcast(tree, init_treenodes)
    bcast(tree, insert_data)
    bcast(tree, insert_data_pseudo)
end