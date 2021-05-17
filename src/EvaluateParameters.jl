#=
Recursively instantiate dependent objects and propagate value in hierarchical NamedTuples

* Developer: Hilding Elmqvist, Mogram AB (initial version)
*            Martin Otter, DLR (instantiation of dependent objects added)
* First version: March 2021
* License: MIT (expat)

=#


using DataStructures: OrderedDict


subst(ex, environment, modelModule) = ex
subst(ex::Symbol, environment, modelModule) = if length(environment) == 0; ex elseif ex in keys(environment[end]); environment[end][ex] else subst(ex, environment[1:end-1], modelModule) end
subst(ex::Expr, environment, modelModule) = Expr(ex.head, [subst(a, environment, modelModule) for a in ex.args]...)
subst(ex::Vector{Symbol}, environment, modelModule) = [subst(a, environment, modelModule) for a in ex]
subst(ex::Vector{Expr}  , environment, modelModule) = [Core.eval(modelModule, subst(a, environment, modelModule)) for a in ex]

#=
function propagate(model, environment=[])
    #println("\n... Propagate: ", model)
    current = OrderedDict()
    for (k,v) in zip(keys(model), model)
        if k in [:class, :_Type]
            current[k] = v
        elseif typeof(v) <: NamedTuple
            current[k] = propagate(v, vcat(environment, [current]))
        else
            evalv = v
            try 
                evalv = eval(subst(v, vcat(environment, [current])))
            catch e
            end

            if typeof(evalv) <: NamedTuple
                current[k] = v
            else
                current[k] = evalv
            end
        end
    end 
    return (; current...)
end
=#



appendKey(path, key) = path == "" ? string(key) : path * "." * string(key)


"""
    map = propagateEvaluateAndInstantiate!(modelModule::Module, model, 
                   eqInfo::ModiaBase.EquationInfo, x_start; log=false)
    
Recursively traverse the hierarchical collection `model` and perform the following actions:

- Propagate values.
- Evaluate expressions in the context of `modelModule`.
- Instantiate dependent objects.
- Store start values of states with key x_name in x_start::Vector{FloatType} 
  (which has length eqInfo.nx).
- Return the evaluated `model` as map::TinyModia.Map if successfully evaluated, and otherwise 
  return nothing, if an error occured (an error message was printed).
"""
function propagateEvaluateAndInstantiate!(modelModule, model, eqInfo, x_start; log=false)
    x_found = fill(false, length(eqInfo.x_info))
    map = propagateEvaluateAndInstantiate2!(modelModule, model, eqInfo, x_start, x_found, [], ""; log=log)
    if isnothing(map)
        return nothing
    end
    
    # Check that all values of x_start are set:
    x_start_missing = []
    for (i, found) in enumerate(x_found)
        if !found
            push!(x_start_missing, equationInfo.x_info[i].x_name)
        end
    end
    if length(x_start_missing) > 0
        printstyled("Model error: ", bold=true, color=:red)  
        printstyled("Missing start/init values for variables: ", x_start_missing, 
                    bold=true, color=:red)
        return nothing
    end
    return map
end

        
function propagateEvaluateAndInstantiate2!(modelModule, model, eqInfo::ModiaBase.EquationInfo, 
                                           x_start::Vector{FloatType}, x_found::Vector{Bool}, 
                                           environment, path::String; log=false) where {FloatType}
    if log
        println("\n!!! instantiate objects of $path: ", model)
    end
    current = OrderedDict()
    
    # Determine, whether the "model" has a ":_constructor" key and handle this specially
    constructor = nothing
    usePath     = false
    if haskey(model, :_constructor)
        # For example: obj = (class = :Par, _constructor = :(Modia3D.Object3D), _path = true, kwargs...)
        #          or: rev = (_constructor = (class = :Par, value = :(Modia3D.ModiaRevolute), _path=true), kwargs...)    
        v = model[:_constructor]
        if typeof(v) <: NamedTuple
            constructor = v[:value]
            if haskey(v, :_path)
                usePath = v[:_path]
            end
        else
            constructor = v
            if haskey(model, :_path)
                usePath = model[:_path]
            end
        end
        
    elseif haskey(model, :value)
        # For example: p1 = (class = :Var, parameter = true, value = 0.2)
        #          or: p2 = (class = :Var, parameter = true, value = :(2*p1))
        v = model[:value]
        veval = Core.eval(modelModule, subst(v, vcat(environment, [current]), modelModule))
        return veval
    end
    
    for (k,v) in zip(keys(model), model)
        if log
            println("    ... key = $k, value = $v")
        end
        if k == :_constructor || k == :_path || (k == :class && !isnothing(constructor))
            nothing
            
        elseif !isnothing(constructor) && (k == :value || k == :init || k == :start)
            error("value, init or start keys are not allowed in combination with a _constructor:\n$model")
            
        elseif typeof(v) <: NamedTuple    
            if haskey(v, :class) && v[:class] == :Par && haskey(v, :value)
                # For example: k = (class = :Par, value = 2.0) -> k = 2.0
                #          or: k = (class = :Par, value = :(2*Lx - 3))   -> k = eval( 2*Lx - 3 )   
                #          or: k = (class = :Par, value = :(bar.frame0)) -> k = ref(bar.frame0)
                subv = subst(v[:value], vcat(environment, [current]), modelModule)
                if log
                    println("    class & value: $k = $subv  # before eval")
                end
                current[k] = Core.eval(modelModule, subv)
                if log
                    println("                   $k = ", current[k])
                end
            else
                # For example: k = (a = 2.0, b = :(2*Lx))
                value = propagateEvaluateAndInstantiate2!(modelModule, v, eqInfo, x_start, x_found, vcat(environment, [current]), appendKey(path, k); log=log)     
                if isnothing(value)
                    return nothing
                end
                current[k] = value
            end
            
        else
            if log
                println("    else: typeof(v) = ", typeof(v))
            end
            subv = subst(v, vcat(environment, [current]), modelModule)
            if log
                println("          $k = $subv   # before eval")
            end
            current[k] = Core.eval(modelModule, subv)
            if log
                println("          $k = ", current[k])
            end
            
            # Set x_start
            full_key = appendKey(path, k) 
            if haskey(eqInfo.x_dict, full_key)
                if log
                    println("              (is stored in x_start)")
                end
                j = eqInfo.x_dict[full_key]
                xe_info = eqInfo.x_info[j]                
                x_value = current[k]
                len = hasParticles(x_value) ? 1 : length(x_value)
                if len != xe_info.length
                    printstyled("Model error: ", bold=true, color=:red)  
                    printstyled("Length of ", xe_info.x_name, " shall be changed from ",
                                xe_info.length, " to $len\n",
                                "This is currently not support in TinyModia.", bold=true, color=:red)
                    return nothing
                end                    
                x_found[j] = true

                # Temporarily remove units from x_start
                # (TODO: should first transform to the var_unit units and then remove)    
                if xe_info.length == 1
                    x_start[xe_info.startIndex] = deepcopy( convert(FloatType, ustrip(x_value)) )
                else
                    ibeg = xe_info.startIndex - 1
                    for i = 1:xe_info.length
                        x_start[ibeg+i] = deepcopy( convert(FloatType, ustrip(x_value[i])) )
                    end
                end
            end
        end
    end 
    
    if isnothing(constructor)
        return (; current...)
    else
        if usePath
            obj = Core.eval(modelModule, :($constructor(; path = $path, $current...))) 
        else
            obj = Core.eval(modelModule, :($constructor(; $current...)))
        end
        if log
            println("    +++ $path: typeof(obj) = ", typeof(obj), ", obj = ", obj, "\n\n")    
        end
        return obj        
    end
end



"""
    getIdParameter(par, id)
    
Search recursively in NamedTuple `par` for a NamedTuple that has 
`key = :_id, value = id` and return this NamedTuple or nothing,
if not present.
"""
function getIdParameter(par::NamedTuple, id::Int)
    if haskey(par, :_id) && par[:_id] == id
        return par
    else
        for (key,value) in zip(keys(par), par)
            if typeof(value) <: NamedTuple
                result = getIdParameter(value, id)
                if !isnothing(result)
                    return result
                end
            end
        end   
    end
    return nothing
end
