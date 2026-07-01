using CSV, DataFrames, Plots
using Dates

tablas_path = joinpath(@__DIR__, "Tablas_Resultados_ED")
graficos_path = joinpath(@__DIR__, "Graficos_Resultados")
mkpath(graficos_path)

# 1. Gráfico de Áreas Apiladas (Despacho)
df_despacho = CSV.read(joinpath(tablas_path, "1_despachos_generacion.csv"), DataFrame)
horas = 0:23

gen_cols = ["gen-1", "gen-2", "gen-4", "gen-5", "gen-solar"]
labels = ["Gen 1 (Termico)" "Gen 2 (Termico)" "Gen 4 (Termico)" "Gen 5 (Termico)" "Gen Solar"]
matriz_despacho = Matrix(df_despacho[!, gen_cols])

# Colores amigables y profesionales
colores_gen = [:firebrick :darkorange :gold :saddlebrown :dodgerblue]

p1 = areaplot(horas, matriz_despacho, 
              labels=labels,
              title="Despacho de Generacion vs Demanda",
              xlabel="Hora del dia", 
              ylabel="Potencia Activa (MW)",
              legend=:topleft,
              color=colores_gen,
              alpha=0.7)
plot!(p1, horas, df_despacho.Demanda_Total_MW, 
      label="Demanda Total", 
      color=:black, 
      linewidth=3, 
      linestyle=:dash)
savefig(p1, joinpath(graficos_path, "1_despacho_areas.png"))

# 2. Gráfico de Costo Marginal
df_lambda = CSV.read(joinpath(tablas_path, "4_costo_marginal.csv"), DataFrame)
p2 = plot(horas, df_lambda.Lambda_MW,
          title="Costo Marginal del Sistema (λ)",
          xlabel="Hora del dia",
          ylabel="Costo (USD/MWh)",
          label="λ (Costo Marginal)",
          color=:purple,
          linewidth=3,
          marker=:circle)
savefig(p2, joinpath(graficos_path, "2_costo_marginal.png"))

# 3. Gráfico de Tensiones (Barras críticas)
tipo_contingencia = ["line", "gen", "normal"]


for contingencia in tipo_contingencia
    df_voltaje = CSV.read(joinpath(tablas_path, "5_perfiles_voltaje_modo_$(contingencia).csv"), DataFrame)
    # Identificar barras críticas (las que tienen los valores mínimos)
    barras_cols = names(df_voltaje)[2:end]
    min_voltages = [minimum(df_voltaje[!, b]) for b in barras_cols]
    # Ordenar de menor a mayor para obtener las más críticas
    sorted_idx = sortperm(min_voltages)
    barras_criticas = barras_cols[sorted_idx[1:4]] # Top 4 peores barras

    if contingencia == "line"
        tipo_titulo = "Caida de línea 2-3"
    elseif contingencia == "gen"
        tipo_titulo = "Caída de generador 2"
    else 
        tipo_titulo = "Funcionamiento normal"
    end

    p3 = plot(title="Perfil de Tension de barras Criticas - $(tipo_titulo)",
            xlabel="Hora del dia",
            ylabel="Magnitud de Tension (pu)",
            legend=:bottomleft)
    # Límites de norma técnica
    hline!(p3, [0.95, 1.05], color=:red, linestyle=:dash, label="Límites Norma", linewidth=2)

    colores_b = [:blue, :green, :orange, :magenta]
    for (i, b) in enumerate(barras_criticas)
        plot!(p3, horas, df_voltaje[!, b], label=replace(b, "_" => " "), linewidth=2, color=colores_b[i], marker=:x)
    end
    # Ajustar el límite y (y-axis) para visualizar mejor si no llegan a 0.95
    # ylims!(p3, (0.94, 1.06))
    savefig(p3, joinpath(graficos_path, "3_perfiles_tension_criticos_modo_$(contingencia).png"))
end


# 4. Gráfico de Tensiones (Todas las barras)

for contingencia in tipo_contingencia
    df_voltaje = CSV.read(joinpath(tablas_path, "5_perfiles_voltaje_modo_$(contingencia).csv"), DataFrame)

    if contingencia == "line"
        tipo_titulo = "Caida de línea 2-3"
    elseif contingencia == "gen"
        tipo_titulo = "Caída de generador 2"
    else 
        tipo_titulo = "Funcionamiento normal"
    end


    p4 = plot(title="Perfil de Tension de Barras - $(tipo_titulo)",
            xlabel="Hora del dia",
            ylabel="Magnitud de Tension (pu)",
            legend=:outerbottom,
            legend_column = 5,
            legendfontsize = 7,
            size = (720, 480))
    # Límites de norma técnica
    hline!(p4, [0.95, 1.05], color=:red, linestyle=:dash, label="Límites Norma", linewidth=2)

    for (i, b) in enumerate(names(df_voltaje)[2:end])
        plot!(p4, horas, df_voltaje[!, b], label=replace(b, "_" => " "), linewidth=2)
    end
    savefig(p4, joinpath(graficos_path, "4_perfiles_tension_completo_modo_$(contingencia).png"))
end


# 5. Gráfico de Tensiones en periodo de contingencia (Todas las barras)

for contingencia in tipo_contingencia
    df_voltaje = CSV.read(joinpath(tablas_path, "5_perfiles_voltaje_modo_$(contingencia).csv"), DataFrame)

    if contingencia == "line"
        tipo_titulo = "Caida de línea 2-3"
    elseif contingencia == "gen"
        tipo_titulo = "Caída de generador 2"
    else 
        tipo_titulo = "Funcionamiento normal"
    end

    p5 = plot(title="Perfil de Tension de Barras - $(tipo_titulo)",
            xlabel="Hora del dia",
            ylabel="Magnitud de Tension (pu)",
            legend=:outerbottom,
            legend_column = 5,
            legendfontsize = 7,
            size = (720, 480))
    # Límites de norma técnica
    hline!(p5, [0.95, 1.05], color=:red, linestyle=:dash, label="Límites Norma", linewidth=2)

    for (i, b) in enumerate(names(df_voltaje)[2:end])
        plot!(p5, horas, df_voltaje[!, b], label=replace(b, "_" => " "), linewidth=2)
    end
    # límite de plot para efecto de zoom
    xlims!(p5, (18, 23))
    savefig(p5, joinpath(graficos_path, "5_perfiles_tension_zoom_modo_$(contingencia).png"))
end


# 6. Gráfico de Tensiones en periodo de contingencia (Barras fuera de norma)

for contingencia in tipo_contingencia
    df_voltaje = CSV.read(joinpath(tablas_path, "5_perfiles_voltaje_modo_$(contingencia).csv"), DataFrame)

    if contingencia == "line"
        tipo_titulo = "Caida de línea 2-3"
    elseif contingencia == "gen"
        tipo_titulo = "Caída de generador 2"
    else 
        tipo_titulo = "Funcionamiento normal"
    end

    p6 = plot(title="Perfil de Tension de Barras - $(tipo_titulo)",
            xlabel="Hora del dia",
            ylabel="Magnitud de Tension (pu)",
            legend=:outerbottom,
            legend_column = 5,
            legendfontsize = 7,
            size = (720, 480))
    # Límites de norma técnica
    hline!(p6, [0.95, 1.05], color=:red, linestyle=:dash, label="Límites Norma", linewidth=2)

    for (i, b) in enumerate(names(df_voltaje)[2:end])
        #sólo aquellos que estén fuera de norma
        voltajes = df_voltaje[!, b]
        if any(voltajes .< 0.95) || any(voltajes .> 1.05)
            plot!(p6, horas, voltajes, label=replace(b, "_" => " "), linewidth=2)
        end
    end
    # límite de plot para efecto de zoom
    xlims!(p6, (18, 23))
    savefig(p6, joinpath(graficos_path, "6_perfiles_tension_critivos_modo_$(contingencia).png"))
end

# 6. Gráfico de Potencia generada por hora y generador según contingencia

for contingencia in tipo_contingencia
    df_voltaje = CSV.read(joinpath(tablas_path, "7_generación_generacion_modo_$(contingencia).csv"), DataFrame)

    if contingencia == "line"
        tipo_titulo = "Caida de línea 2-3"
    elseif contingencia == "gen"
        tipo_titulo = "Caída de generador 2"
    else 
        tipo_titulo = "Funcionamiento normal"
    end

    p6 = plot(title="Perfil de Tension de Barras - $(tipo_titulo)",
            xlabel="Hora del dia",
            ylabel="Magnitud de Tension (pu)",
            legend=:outerbottom,
            legend_column = 5,
            legendfontsize = 7,
            size = (720, 480))
    # Límites de norma técnica
    hline!(p6, [0.95, 1.05], color=:red, linestyle=:dash, label="Límites Norma", linewidth=2)

    for (i, b) in enumerate(names(df_voltaje)[2:end])
        #sólo aquellos que estén fuera de norma
        voltajes = df_voltaje[!, b]
        if any(voltajes .< 0.95) || any(voltajes .> 1.05)
            plot!(p6, horas, voltajes, label=replace(b, "_" => " "), linewidth=2)
        end
    end
    # límite de plot para efecto de zoom
    xlims!(p6, (18, 23))
    savefig(p6, joinpath(graficos_path, "6_perfiles_tension_critivos_modo_$(contingencia).png"))
end




println("Graficos generados exitosamente en la carpeta '$graficos_path'.")
