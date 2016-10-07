using DSGE, DataFrames, HDF5, DistributedArrays
include("../util.jl")

path = dirname(@__FILE__())

# Set up arguments
custom_settings = Dict{Symbol, Setting}(
    :date_forecast_start  => Setting(:date_forecast_start, quartertodate("2015-Q4")),
    :use_parallel_workers => Setting(:use_parallel_workers, true),
    :forecast_pseudoobservables => Setting(:forecast_pseudoobservables, true))
m = Model990(custom_settings = custom_settings, testing = true)

params_sim = h5open("$path/../reference/filter_args.h5","r") do h5
    read(h5, "params_sim")
end

df = load_data(m; try_disk = true, verbose = :none)

# Add parallel workers
ndraws = 2
my_procs = addprocs(ndraws)
@everywhere using DSGE

# Set up systems
function init_systems(m, params_sim, ndraws, my_procs)
    DArray((ndraws,), my_procs, [length(my_procs)]) do I
        draw_inds = first(I)
        ndraws_local = length(draw_inds)
        localpart = Vector{System{Float64}}(ndraws_local)

        for i in draw_inds
            i_local = mod(i-1, ndraws_local) + 1

            params = squeeze(params_sim[i, :], 1)
            update!(m, params)
            localpart[i_local] = compute_system(m)
        end
        return localpart
    end
end
systems = init_systems(m, params_sim, ndraws, my_procs)

z0  = (eye(n_states_augmented(m)) - systems[1][:TTT]) \ systems[1][:CCC]
vz0 = QuantEcon.solve_discrete_lyapunov(systems[1][:TTT], systems[1][:RRR]*systems[1][:QQ]*systems[1][:RRR]')

# Run to compile before timing
states, shocks, pseudo = filterandsmooth(m, df, systems; procs = my_procs)
states, shocks, pseudo = filterandsmooth(m, df, systems, z0, vz0; procs = my_procs)

for smoother in [:durbin_koopman, :kalman]
    m <= Setting(:forecast_smoother, smoother)

    # Without providing z0 and vz0
    @time states, shocks, pseudo = filterandsmooth(m, df, systems; procs = my_procs)

    exp_states = Vector{Matrix{Float64}}(ndraws)
    exp_shocks = Vector{Matrix{Float64}}(ndraws)
    exp_pseudo = Vector{Matrix{Float64}}(ndraws)
    for i = 1:ndraws
        kal = kalman_filter(m, df_to_matrix(m, df), systems[i][:TTT], systems[i][:CCC], systems[i][:ZZ],
                            systems[i][:DD], systems[i][:VVall]; allout = true)

        exp_states[i], exp_shocks[i] = if forecast_smoother(m) == :durbin_koopman
            durbin_koopman_smoother(m, df, systems[i], kal[:z0], kal[:vz0])
        elseif forecast_smoother(m) == :kalman
            kalman_smoother(m, df, systems[i], kal[:z0], kal[:vz0], kal[:pred], kal[:vpred])
        end

        _, pseudo_mapping = pseudo_measurement(m)
        exp_pseudo[i] = pseudo_mapping.ZZ * exp_states[i] .+ pseudo_mapping.DD

        @test_matrix_approx_eq exp_states[i] convert(Array, slice(states, i, :, :))
        @test_matrix_approx_eq exp_shocks[i] convert(Array, slice(shocks, i, :, :))
        @test_matrix_approx_eq exp_pseudo[i] convert(Array, slice(pseudo, i, :, :))
    end

    # Providing z0 and vz0
    @time states, shocks, pseudo = filterandsmooth(m, df, systems, z0, vz0; procs = my_procs)

    exp_states = Vector{Matrix{Float64}}(ndraws)
    exp_shocks = Vector{Matrix{Float64}}(ndraws)
    exp_pseudo = Vector{Matrix{Float64}}(ndraws)
    for i = 1:ndraws
        kal = kalman_filter(m, df_to_matrix(m, df), systems[i][:TTT], systems[i][:CCC], systems[i][:ZZ],
                            systems[i][:DD], systems[i][:VVall], z0, vz0; allout = true)

        exp_states[i], exp_shocks[i] = if forecast_smoother(m) == :durbin_koopman
            durbin_koopman_smoother(m, df, systems[i], kal[:z0], kal[:vz0])
        elseif forecast_smoother(m) == :kalman
            kalman_smoother(m, df, systems[i], kal[:z0], kal[:vz0], kal[:pred], kal[:vpred])
        end

        _, pseudo_mapping = pseudo_measurement(m)
        exp_pseudo[i] = pseudo_mapping.ZZ * exp_states[i] .+ pseudo_mapping.DD

        @test_matrix_approx_eq exp_states[i] convert(Array, slice(states, i, :, :))
        @test_matrix_approx_eq exp_shocks[i] convert(Array, slice(shocks, i, :, :))
        @test_matrix_approx_eq exp_pseudo[i] convert(Array, slice(pseudo, i, :, :))
    end

end

# Remove parallel workers
rmprocs(my_procs)

nothing