using CSV, DataFrames, Plots
using Dates


include_in_grid  = ["BESS", "statcom"]   # "BESS", "statcom"
extra_descriptor = join(include_in_grid, "_")

tipo_contingencia = ["line", "gen", "normal"]
barras            = [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]

tablas_path   = joinpath(@__DIR__, "Tablas_Resultados_ED_2")
graficos_path = joinpath(@__DIR__, "Graficos_Resultados_2")
mkpath(graficos_path)

horas = 0:23

titulo_contingencia = Dict(
    "line"   => "Caida de línea 2-3",
    "gen"    => "Caída de generador 2",
    "normal" => "Funcionamiento normal",
)

# Si se ocupa statcom, itera por las barras
descriptores = "statcom" in include_in_grid ?
    ["$(extra_descriptor)_barra_$(b)" for b in barras] :
    [extra_descriptor]

# ==========================================================
# 1. Gráfico de Despacho
# ==========================================================
df_despacho = CSV.read(joinpath(tablas_path, "1_despachos_generacion_$(extra_descriptor).csv"), DataFrame)

gen_cols    = ["gen-1", "gen-2", "gen-4", "gen-5", "gen-solar"]
labels      = ["Gen 1 (Termico)" "Gen 2 (Termico)" "Gen 4 (Termico)" "Gen 5 (Termico)" "Gen Solar"]
colores_gen = [:firebrick :darkorange :gold :saddlebrown :dodgerblue :turquoise :black :purple]

if "BESS" in include_in_grid
    push!(gen_cols, "Net_BESS")
    labels = hcat(labels, "Net_BESS")
end


matriz_despacho = Matrix(df_despacho[!, gen_cols])

p1 = areaplot(horas, matriz_despacho,
              labels=labels,
              title="Despacho de Generacion vs Demanda",
              xlabel="Hora del dia",
              ylabel="Potencia Activa (MW)",
              legend=:topleft,
              color=colores_gen,
              alpha=0.7)
plot!(p1, horas, df_despacho.Demanda_Total_MW,
      label="Demanda Total", color=:black, linewidth=3, linestyle=:dash)
savefig(p1, joinpath(graficos_path, "1_despacho_areas_$(extra_descriptor).png"))


# ==========================================================
# Función perfil de tensión
# ==========================================================
"""
Grafica el perfil de tensión de las barras de `df_voltaje`.

- modo = :criticas       -> sólo las 4 barras con menor tensión mínima (equivalente al gráfico 3 original)
- modo = :completo       -> todas las barras (gráficos 4 y 5 originales; usar `rango_x` para el zoom)
- modo = :fuera_de_norma -> sólo barras que en algún momento violan [0.95, 1.05] (gráfico 6 original)
"""
function graficar_perfil_tension(df_voltaje, tipo_titulo, horas; modo=:completo, rango_x=nothing)
    p = plot(title="Perfil de Tension de Barras - $(tipo_titulo)",
             xlabel="Hora del dia", ylabel="Magnitud de Tension (pu)",
             legend = :outerbottom,
             legend_column = 5, legendfontsize = 7,
             size = (720, 480))

    hline!(p, [0.95, 1.05], color=:red, linestyle=:dash, label="Límites Norma", linewidth=2)

    columnas = names(df_voltaje)[2:end]

    if modo == :criticas
        min_voltages      = [minimum(df_voltaje[!, b]) for b in columnas]
        columnas_criticas = columnas[sortperm(min_voltages)[1:4]]
        colores_b = [:blue, :green, :orange, :magenta]
        for (i, b) in enumerate(columnas_criticas)
            plot!(p, horas, df_voltaje[!, b], label=replace(b, "_" => " "),
                  linewidth=2, color=colores_b[i], marker=:x)
        end
    elseif modo == :fuera_de_norma
        for b in columnas
            v = df_voltaje[!, b]
            if any(v .< 0.95) || any(v .> 1.05)
                plot!(p, horas, v, label=replace(b, "_" => " "), linewidth=2)
            end
        end
    else # :completo
        for b in columnas
            plot!(p, horas, df_voltaje[!, b], label=replace(b, "_" => " "), linewidth=2)
        end
    end

    rango_x !== nothing && xlims!(p, rango_x)
    return p
end

# ==========================================================
# 3, 4, 5, 6. Perfiles de tensión (críticas / completo / zoom / fuera de norma)
# ==========================================================
for contingencia in tipo_contingencia
    tipo_titulo = titulo_contingencia[contingencia]

    for desc in descriptores
        df_voltaje = CSV.read(
            joinpath(tablas_path, "5_perfiles_voltaje_modo_$(desc)_$(contingencia).csv"),
            DataFrame,
        )

        p3 = graficar_perfil_tension(df_voltaje, tipo_titulo, horas; modo=:criticas)
        savefig(p3, joinpath(graficos_path, "3_perfiles_tension_criticos_modo_$(desc)_$(contingencia).png"))

        p4 = graficar_perfil_tension(df_voltaje, tipo_titulo, horas; modo=:completo)
        savefig(p4, joinpath(graficos_path, "4_perfiles_tension_completo_modo_$(desc)_$(contingencia).png"))

        # zoom
        p5 = graficar_perfil_tension(df_voltaje, tipo_titulo, horas; modo=:completo, rango_x=(18, 23))
        savefig(p5, joinpath(graficos_path, "5_perfiles_tension_zoom_modo_$(desc)_$(contingencia).png"))

        p6 = graficar_perfil_tension(df_voltaje, tipo_titulo, horas; modo=:fuera_de_norma, rango_x=(18, 23))
        savefig(p6, joinpath(graficos_path, "6_perfiles_tension_critivos_modo_$(desc)_$(contingencia).png"))
    end
end

# ==========================================================
# 7. Análisis de compensación (barra slack)
# ==========================================================
function graficar_compensacion(df_compensacion, horas)
    p = plot(title="Compensacion de Perdidas en Generadores",
             xlabel="Hora del dia", ylabel="Desviacion P_real vs P_despacho (MW)",
             legend=:topleft)

    cols_dev    = names(df_compensacion)[2:end]
    colores_dev = [:firebrick, :dodgerblue, :darkorange, :forestgreen, :purple]

    for (i, col) in enumerate(cols_dev)
        nombre_gen = replace(col, "Dev_MW_" => "")
        if nombre_gen == "gen-1"
            plot!(p, horas, df_compensacion[!, col], label="$(nombre_gen) (Slack)",
                  linewidth=3, color=colores_dev[i], marker=:circle)
        else
            plot!(p, horas, df_compensacion[!, col], label=nombre_gen,
                  linewidth=2, linestyle=:dash, color=colores_dev[i])
        end
    end

    ylims!(p, (-4.7, maximum(df_compensacion[!, "Dev_MW_gen-1"]) * 1.2))
    return p
end

for contingencia in tipo_contingencia
    for desc in descriptores
        df_compensacion = CSV.read(
            joinpath(tablas_path, "6_analisis_compensacion_$(desc)_$(contingencia).csv"),
            DataFrame,
        )
        p7 = graficar_compensacion(df_compensacion, horas)
        savefig(p7, joinpath(graficos_path, "7_analisis_compensacion_$(desc)_$(contingencia).png"))
    end
end

println("Graficos generados exitosamente en la carpeta '$graficos_path'.")