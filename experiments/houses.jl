# sparclur, sparclur relaxation, sparse relaxation, lasso, ORT point
# bonus: sparse no relaxation, ORT linear

import SparClur2
import CSV
import CPLEX
import MLDataUtils: kfolds
import StatsBase: mean
using DataFrames # TODO remove
using GLMNet

data_dir = "experiments/data"

optimizer = CPLEX.Optimizer
optimizer_params = ("CPX_PARAM_TILIM" => 120, "CPXPARAM_MIP_Tolerances_MIPGap" => 1e-2)

gamma_range = [1e-7, 1e-6, 1e-4, 0.001, 0.03, 0.01, 0.1, 1.0, 10.0, 100.0]
q_range = 1:10
silent = true
depths = 0:5

# allow clusters to be an input in case of empty clusters
function make_clusters(X_list, Y_list, memberships_list, clusters)
    Xs = AbstractMatrix{Float64}[view(X_list, 1:1, :) for _ in clusters] # TODO
    Ys = AbstractVector{Float64}[[] for _ in clusters] # TODO view
    for (c, cluster) in enumerate(clusters)
        idxs = findall(x -> x .== cluster, memberships_list)
        Xs[c] = view(X_list, idxs, :)
        Ys[c] = view(Y_list, idxs)
    end
    return (Xs, Ys)
end

# heuristic for warm starts. uses relaxation algorithm, only trying a fixed set of gammas.
function get_warm_start(Xs, Ys, q::Int)
    best_mse = Inf
    best_supp = []
    for gamma in 10.0 .^ (-1:2)
        (supp, _, weights) = SparClur2.solve_relaxation(Xs, Ys, q, gamma = gamma)
        Y_pred = [Xs[i][:, supp] * weights[i] for i in eachindex(Ys)]
        mse = sum(sum(abs2, Y_pred[i] - Ys[i]) for i in eachindex(Ys))
        if mse < best_mse
            best_mse = mse
            best_supp = supp
        end
    end
    warm_start = zeros(size(Xs[1], 2))
    warm_start[best_supp] .= 1
    return warm_start
end

function read_data(depth::Int, seed::Int, train::Bool)
    if train
        data = Array(CSV.read(joinpath(data_dir, "const_depth$(depth)_train_s$(seed).csv"), DataFrame))
    else
        data = Array(CSV.read(joinpath(data_dir, "const_depth$(depth)_test_s$(seed).csv"), DataFrame))
    end
    X_list = hcat(ones(size(data, 1)), data[:, 1:(end - 3)])
    Y_list = data[:, end - 2]
    memberships = Int.(data[:, end])
    return (X_list, Y_list, memberships)
end

function train_sparclur(depth, seed; relaxation = true, ignore_coordination = false)
    (X_big_list, Y_big_list, memberships_list) = read_data(depth, seed, true)
    (num_obs, num_features) = size(X_big_list)
    clusters = unique(memberships_list) # not contiguous
    folds = kfolds(collect(1:num_obs), k = 5)
    mse_scores = zeros(length(q_range), length(gamma_range))
    valid_io = open("validation_depth$(depth).csv", "w")
    println(valid_io, "fold,q,gamma,mse")
    for (fold_idx, (train_idxs, valid_idxs)) in enumerate(folds)
        # split data
        X_train_list = view(X_big_list, train_idxs, :)
        X_valid_list = view(X_big_list, valid_idxs, :)
        Y_train_list = view(Y_big_list, train_idxs)
        Y_valid_list = view(Y_big_list, valid_idxs)
        memberships_train = view(memberships_list, train_idxs)
        memberships_valid = view(memberships_list, valid_idxs)
        # group by leaves
        (Xs_train, Ys_train) = make_clusters(X_train_list, Y_train_list, memberships_train, clusters)
        (Xs_valid, Ys_valid) = make_clusters(X_valid_list, Y_valid_list, memberships_valid, clusters)
        # grid
        for (gamma_idx, gamma) in enumerate(gamma_range)
            for (q_idx, q) in enumerate(q_range)
                if relaxation
                    if ignore_coordination
                        supp = Vector{Int}[]
                        weights = Vector{Float64}[]
                        # one leaf = single cluster at a time
                        for c in eachindex(clusters)
                            (supp_c, num_supp, weights_c) = SparClur2.solve_relaxation([Xs_train[c]], [Ys_train[c]], q, gamma = gamma)
                            push!(supp, supp_c[1:num_supp])
                            push!(weights, weights_c[1])
                        end
                    else
                        (supp_c, _, weights) = SparClur2.solve_relaxation(Xs_train, Ys_train, q, gamma = gamma)
                        # repeat the same support for all clusters (tidy this line)
                        supp = fill(supp_c, length(clusters))
                    end
                else
                    if ignore_coordination
                        supp = Vector{Int}[]
                        weights = Vector{Float64}[]
                        # one leaf = single cluster at a time
                        for c in eachindex(clusters)
                            warm_start = get_warm_start([Xs_train[c]], [Ys_train[c]], q)
                            (supp_c, weights_c) = SparClur2.solve_MIOP([Xs_train[c]], [Ys_train[c]], q, gamma, optimizer, silent = silent, optimizer_params = optimizer_params, bin_init = warm_start)
                            push!(supp, supp_c)
                            push!(weights, weights_c[1])
                        end
                    else
                        warm_start = get_warm_start(Xs_train, Ys_train, q)
                        (supp_c, weights) = SparClur2.solve_MIOP(Xs_train, Ys_train, q, gamma, optimizer, silent = silent, optimizer_params = optimizer_params, bin_init = warm_start)
                        # repeat the same support for all clusters (tidy this line)
                        supp = fill(supp_c, length(clusters))
                    end
                end
                Ys_pred = [Xs_valid[c][:, supp[c]] * weights[c] for c in eachindex(clusters)]
                score = sum(sum(abs2, Ys_pred[c] - Ys_valid[c]) for c in eachindex(clusters))
                mse_scores[q_idx, gamma_idx] += sum(sum(abs2, Ys_pred[c] - Ys_valid[c]) for c in eachindex(clusters))
                println(valid_io, "$(fold_idx),$(q),$(gamma),$(mse_scores[q_idx, gamma_idx])")
                flush(valid_io)
            end
        end
    end
    close(valid_io)

    (_, best_idx) = findmin(mse_scores)
    (best_q, best_gamma) = (q_range[best_idx[1]], gamma_range[best_idx[2]])
    @show best_q
    # retrain
    (Xs_big, Ys_big) = make_clusters(X_big_list, Y_big_list, memberships_list, clusters)
    if relaxation
        if ignore_coordination
            supp = Vector{Int}[]
            weights = Vector{Float64}[]
            # one leaf = single cluster at a time
            for c in eachindex(clusters)
                (supp_c, num_supp, weights_c) = SparClur2.solve_relaxation([Xs_big[c]], [Ys_big[c]], best_q[c], gamma = best_gamma[c])
                push!(supp, supp_c[1:num_supp])
                push!(weights, weights_c[1])
            end
        else
            (supp_c, num_supp, weights) = SparClur2.solve_relaxation(Xs_big, Ys_big, best_q, gamma = best_gamma)
            supp = fill(supp_c[1:num_supp], length(clusters))
        end
    else
        if ignore_coordination
            supp = Vector{Int}[]
            weights = Vector{Float64}[]
            # one leaf = single cluster at a time
            for c in eachindex(clusters)
                warm_start = get_warm_start([Xs_big[c]], [Ys_big[c]], best_q)
                (supp_c, weights_c) = SparClur2.solve_MIOP([Xs_big[c]], [Ys_big[c]], best_q[c], best_gamma[c], optimizer, silent = silent, optimizer_params = optimizer_params, bin_init = warm_start)
                push!(supp, supp_c)
                push!(weights, weights_c[1])
            end
        else
            warm_start = get_warm_start(Xs_big, Ys_big, best_q)
            (supp_c, weights) = SparClur2.solve_MIOP(Xs_big, Ys_big, best_q, best_gamma, optimizer, silent = silent, optimizer_params = optimizer_params, bin_init = warm_start)
            supp = fill(supp_c, length(clusters))
        end
    end
    return (clusters, best_gamma, (supp, weights))
end

# sol = train_sparclur(5, 1, relaxation = false, ignore_coordination = false)
# (clusters, best_gamma, (supp, weights)) = sol
# depth = 5; seed = 1;
# (X_list, Y_list, memberships_list) = read_data(depth, seed, false)
# (Xs_test, Ys_test) = make_clusters(X_list, Y_list, memberships_list, clusters)
# Ys_pred = [Xs_test[c][:, supp[c]] * weights[c] for c in eachindex(clusters)]
# mse = sum(sum(abs2, Ys_pred[c] - Ys_test[c]) for c in eachindex(clusters))
# mean_all = mean(Y_list)
# baseline_mse = sum(sum(abs2, mean_all .- Ys_test[c]) for c in eachindex(clusters))
# r2 = 1 - mse / baseline_mse

function test_sparclur(; ignore_coord = false, use_relaxation = true)
    res = zeros(length(depths))
    for (depth_idx, depth) in enumerate(depths), seed in 1:5
        # (clusters, best_gamma, (supp, weights)) = sol
        (clusters, best_gamma, (supp, weights)) = train_sparclur(depth, seed, relaxation = use_relaxation, ignore_coordination = ignore_coord)
        (X_list, Y_list, memberships_list) = read_data(depth, seed, false)
        (Xs_test, Ys_test) = make_clusters(X_list, Y_list, memberships_list, clusters)
        Ys_pred = [Xs_test[c][:, supp[c]] * weights[c] for c in eachindex(clusters)]
        mse = sum(sum(abs2, Ys_pred[c] - Ys_test[c]) for c in eachindex(clusters))
        mean_all = mean(Y_list)
        baseline_mse = sum(sum(abs2, mean_all .- Ys_test[c]) for c in eachindex(clusters))
        res[depth_idx] = 1 - mse / baseline_mse
        open("output/housing_depth_$(depth)_ignore_coord_$(ignore_coord)_relaxation_$(use_relaxation)_s$(seed).txt", "w") do io
            println(io, supp)
            println(io, weights)
            println(io, res[depth_idx])
            println(io, best_gamma)
        end
    end
    return res
end
# res = test_sparclur()
# @show res

# for use_relaxation in [true, false], ignore_coord in [false, true]
# for use_relaxation in [false], ignore_coord in [false]
#     test_sparclur(ignore_coord = ignore_coord, use_relaxation = use_relaxation)
# end

function sparclur_r2()
    for use_relaxation in [true], ignore_coord in [false], depth in depths
        r2 = 0.0
        for seed in 1:5
            open("output/housing_depth_$(depth)_ignore_coord_$(ignore_coord)_relaxation_$(use_relaxation)_s$(seed).txt", "r") do io
                readline(io)
                readline(io)
                r2 += parse(Float64, readline(io))
            end
        end
        @show use_relaxation, ignore_coord, depth, round(r2 / 5, digits = 3)
    end
end
# sparclur_r2()

function vars_per_leaf(supports)
    num_leaves = length(supports)
    leaf_counts = length.(supports)
    min_leaf = minimum(leaf_counts)
    max_leaf = maximum(leaf_counts)
    mean_leaf = sum(leaf_counts) / num_leaves
    features = unique(vcat(supports...))
    num_repeats = zeros(Int, length(features))
    for supp in supports, (f_idx, f) in enumerate(features)
        if f in supp
            num_repeats[f_idx] += 1
        end
    end
    often = 0
    seldom = 0
    often = count(num_repeats .> div(num_leaves, 2))
    seldom = count(num_repeats .<= div(num_leaves, 2))
    return (min_leaf, max_leaf, mean_leaf, often, seldom)
end

function sparclur_vars()
    for use_relaxation in [true], ignore_coord in [true], depth in depths
        (min_leaf, max_leaf, mean_leaf, often, seldom) = ([], [], [], [], [])
        for seed in 1:5
            open("output/housing_depth_$(depth)_ignore_coord_$(ignore_coord)_relaxation_$(use_relaxation)_s$(seed).txt", "r") do io
                supp_str = readline(io)
                supports = eval(Meta.parse(supp_str))
                (min_leaf_s, max_leaf_s, mean_leaf_s, often_s, seldom_s) = vars_per_leaf(supports)
                push!(min_leaf, min_leaf_s)
                push!(max_leaf, max_leaf_s)
                push!(mean_leaf, mean_leaf_s)
                push!(often, often_s)
                push!(seldom, seldom_s)
            end
        end
        println(round(mean(min_leaf), digits = 3), " ", round(mean(max_leaf), digits = 3), " ", round(mean(mean_leaf), digits = 3), " ", round(mean(often), digits = 3), " ", round(mean(seldom), digits = 3))
    end
end

function test_lasso()
    res = zeros(length(depths))
    for (depth_idx, depth) in enumerate(depths), seed in 1:5
        (X_train_list, Y_train_list, memberships_train) = read_data(depth, seed, true)
        (X_test_list, Y_test_list, memberships_test) = read_data(depth, seed, true)
        clusters = unique(memberships_train)
        (Xs_train, Ys_train) = make_clusters(X_train_list, Y_train_list, memberships_train, clusters)
        (Xs_test, Ys_test) = make_clusters(X_test_list, Y_test_list, memberships_test, clusters)
        mse = 0.0
        for c in eachindex(clusters)
            cv = glmnetcv(Xs_train[c], Ys_train[c])
            Y_pred = Xs_test[c] * cv.path.betas[:, argmin(cv.meanloss)]
            mse += sum(abs2, Y_pred - Ys_test[c])
        end
        baseline_mse = sum(abs2, Y_test_list .- mean(Y_test_list))
        res[depth_idx] += 1 - mse / baseline_mse
    end
    return res ./ length(seeds)
end
# @show round.(test_lasso(), digits = 3)

function test_ort_point()
    res = zeros(length(depths))
    for (depth_idx, depth) in enumerate(depths), seed in 1:5
        data_test = Array(CSV.read(joinpath(data_dir, "const_depth$(depth)_test_s$(seed).csv"), DataFrame))
        Y_pred = data_test[:, end - 1]
        Y_test = data_test[:, end - 2]
        mse = sum(abs2, Y_pred - Y_test)
        baseline_mse = sum(abs2, Y_test .- mean(Y_test))
        res[depth_idx] += 1 - mse / baseline_mse
    end
    return res ./ length(seeds)
end
# @show round.(test_ort_point(), digits = 3)
#
function test_ort_linear()
    res = zeros(length(depths))
    for (depth_idx, depth) in enumerate(depths), seed in 1:5
        data_test = Array(CSV.read(joinpath(data_dir, "linear_depth$(depth)_test_s$(seed).csv"), DataFrame))
        Y_pred = data_test[:, end - 1]
        Y_test = data_test[:, end - 2]
        mse = sum(abs2, Y_pred - Y_test)
        baseline_mse = sum(abs2, Y_test .- mean(Y_test))
        res[depth_idx] += 1 - mse / baseline_mse
    end
    return res ./ length(seeds)
end
# @show round.(test_ort_linear(), digits = 3)
