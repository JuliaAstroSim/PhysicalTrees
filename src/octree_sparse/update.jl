getmass(p::AbstractPoint, ::Nothing) = 0.0
getmass(p::AbstractPoint, u::Units) = 0.0 * u
getpos(p::AbstractPoint) = p
getvel(p::AbstractPoint, ::Nothing) = zero(p)
getvel(p::AbstractPoint, u::Units) = zero(p) * (one(p.x) * u)

getmass(p::Massless2D, ::Nothing) = 0.0
getmass(p::Massless, ::Nothing) = 0.0

getmass(p::AbstractParticle, ::Nothing) = p.Mass
getmass(p::AbstractParticle, u::Units) = uconvert(u, p.Mass)
getpos(p::AbstractParticle) = p.Pos
getvel(p::AbstractParticle, ::Nothing) = p.Vel
getvel(p::AbstractParticle, u::Units) = uconvert(u, p.Vel)

function update_treenodes_kernel(tree::AbstractTree, no::Int64, sib::Int64, father::Int64)
    MaxTreenode = tree.config.MaxTreenode
    treenodes = tree.treenodes
    NextNodes = tree.NextNodes
    ExtNodes = tree.ExtNodes

    uLength = getuLength(tree.units)
    uTime = getuTime(tree.units)
    uMass = getuMass(tree.units)
    uVel = getuVel(tree.units)

    mass = nothing
    s = nothing
    vs = nothing
    hmax = nothing

    if no <= MaxTreenode # internal node
        suns = deepcopy(treenodes[no].DaughterID)

        if tree.last > 0
            if tree.last > MaxTreenode  # pseudo-particle
                NextNodes[tree.last - MaxTreenode] = no
            else
                treenodes[tree.last] = setproperties!!(treenodes[tree.last], NextNode = no)
            end
        end
        tree.last = no

        if isnothing(tree.units)
            mass = 0.0
            s = PVector()
            vs = PVector()
            hmax = 0.0
        else
            mass = 0.0 * uMass
            s = PVector(uLength)
            vs = PVector(uVel)
            hmax = 0.0 * uLength
        end

        for j in 1:8
            p = suns[j]
            if p > 0
                # check if we have a sibling on the same level
                jj = 0
                pp = 0
                for jjj = (j+1) : 9
                    jj = jjj
                    if jj <= 8
                        pp = suns[jj]
                    end
                    if pp > 0
                        break
                    end
                end

                if jj <= 8  # Have sibling
                    nextsib = pp
                else
                    nextsib = sib
                end

                # Depth-First
                update_treenodes_kernel(tree, p, nextsib, no)

                if p <= MaxTreenode
                    mass += treenodes[p].Mass
                    s += ustrip(uMass, treenodes[p].Mass) * treenodes[p].MassCenter
                    vs += ustrip(uMass, treenodes[p].Mass) * ExtNodes[p].vs

                    hmax = max(hmax, ExtNodes[p].hmax)
                else # Pseudo-particle
                    # Nothing to do since we had not updated pseudo data
                end
            end
        end

        if ustrip(mass) > 0.0
            s /= ustrip(uMass, mass)
            vs /= ustrip(uMass, mass)
        else
            s = treenodes[no].Center # Geometric center
        end

        treenodes[no] = setproperties!!(treenodes[no], MassCenter = s,
                                                    Mass = mass,
                                                    BitFlag = 0,
                                                    Sibling = sib,
                                                    Father = father)
        
        ExtNodes[no] = setproperties!!(ExtNodes[no], vs = vs, hmax = hmax)
    else # pseudo particle
        if tree.last > 0
            if tree.last > MaxTreenode  # pseudo-particle
                NextNodes[tree.last - MaxTreenode] = no
            else
                treenodes[tree.last] = setproperties!!(treenodes[tree.last], NextNode = no)
            end
        end
        tree.last = no
    end
end

function finish_last(tree::AbstractTree)
    if tree.last > tree.config.MaxTreenode
        tree.NextNodes[tree.last - tree.config.MaxTreenode] = 0
    else
        tree.treenodes[tree.last] = setproperties!!(tree.treenodes[tree.last], NextNode = 0)
    end
end

function update_local_data(tree::AbstractTree)
    tree.ExtNodes = [ExtNode(tree.units) for i in 1:tree.config.MaxTreenode]
    tree.NextNodes = zeros(Int64, tree.config.MaxTopnode)

    tree.last = 0
    update_treenodes_kernel(tree, 1, 0, 0)
    finish_last(tree)
end

function fill_pseudo_buffer(tree::AbstractTree)
    treenodes = tree.treenodes
    DomainMoment = tree.domain.DomainMoment

    empty!(tree.domain.MomentsToSend)

    for i in tree.domain.DomainMyStart : tree.domain.DomainMyEnd
        no = tree.domain.DomainNodeIndex[i]
        DomainMoment[i] = setproperties!!(DomainMoment[i], Mass = treenodes[no].Mass,
                                                           MassCenter = treenodes[no].MassCenter,
                                                           Vel = tree.ExtNodes[no].vs)
    end

    tree.domain.MomentsToSend = DomainMoment[tree.domain.DomainMyStart:tree.domain.DomainMyEnd]
end

function update_pseudo_data(tree::AbstractTree)
    empty!(tree.domain.MomentsToSend)

    uLength = getuLength(tree.units)
    uTime = getuTime(tree.units)
    uMass = getuMass(tree.units)
    uVel = getuVel(tree.units)

    if isnothing(tree.units)
        sold = PVector()
        snew = PVector()
        vsold = PVector()
        vsnew = PVector()
        massold = 0.0
        massnew = 0.0
    else
        sold = PVector(uLength)
        snew = PVector(uLength)
        vsold = PVector(uVel)
        vsnew = PVector(uVel)
        massold = 0.0 * uMass
        massnew = 0.0 * uMass
    end

    treenodes = tree.treenodes
    NextNodes = tree.NextNodes
    ExtNodes = tree.ExtNodes
    DomainMoment = tree.domain.DomainMoment

    for i in 1:tree.domain.NTopLeaves
        if i < tree.domain.DomainMyStart || i > tree.domain.DomainMyEnd
            no = tree.domain.DomainNodeIndex[i]

            sold = treenodes[no].MassCenter
            vsold = ExtNodes[no].vs
            massold = treenodes[no].Mass

            snew = DomainMoment[i].MassCenter
            vsnew = DomainMoment[i].Vel
            massnew = DomainMoment[i].Mass

            while no > 0
                mm = treenodes[no].Mass + massnew - massold
                if ustrip(mm) > 0.0
                    treenodes[no] = setproperties!!(treenodes[no], MassCenter = (treenodes[no].Mass * treenodes[no].MassCenter +
                                                            massnew * snew - massold * sold) / mm)
                    ExtNodes[no] = setproperties!!(ExtNodes[no], vs = (treenodes[no].Mass * ExtNodes[no].vs +
                                                            massnew * vsnew - massold * vsold) / mm)
                end
                treenodes[no] = setproperties!!(treenodes[no], Mass = mm)
                no = treenodes[no].Father
            end # while
        end # if
    end # for
end

function flag_local_treenodes(tree::AbstractTree)
    treenodes = tree.treenodes
    # mark all top-level nodes
    for i in 1:length(tree.domain.DomainNodeIndex)
        no = tree.domain.DomainNodeIndex[i]

        while no > 0
            if (treenodes[no].BitFlag & 1) > 0
                break
            end

            treenodes[no] = setproperties!!(treenodes[no], BitFlag = treenodes[no].BitFlag | 1)

            no = treenodes[no].Father
        end
    end

    # mark top-level nodes that contain local particles
    for i in tree.domain.DomainMyStart:tree.domain.DomainMyEnd
        no = tree.domain.DomainNodeIndex[i]

        while no > 0
            if (treenodes[no].BitFlag & 2) > 0
                break
            end

            treenodes[no] = setproperties!!(treenodes[no], BitFlag = treenodes[no].BitFlag | 2)

            no = treenodes[no].Father
        end
    end
end

function update(tree::AbstractTree)
    bcast(tree, update_local_data)
    bcast(tree, fill_pseudo_buffer)

    # send pseudo buffer
    tree.domain.DomainMoment = reduce(vcat, gather(tree, :domain, :MomentsToSend))
    bcast(tree, :domain, :DomainMoment, tree.domain.DomainMoment)

    bcast(tree, update_pseudo_data)
    bcast(tree, flag_local_treenodes)
end