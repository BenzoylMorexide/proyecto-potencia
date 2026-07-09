using PowerSystems, PowerSimulations, PowerFlows
using Dates, TimeSeries
using HiGHS
using CSV, DataFrames, Plots
using StorageSystemsSimulations # v0.9.0

# ==============================================================================
# NOTA GENERAL: este script no ha sido ejecutado en un entorno Julia real.
# Está construido sobre la base de tu código original + las correcciones
# discutidas. Los puntos marcados con "# CHEQUEAR:" son API que debes
# verificar en tu versión instalada antes de confiar en el resultado.
# ==============================================================================

# Carpeta para guardar el modelo
ed_model_output = joinpath(@__DIR__, "ED_model")
if !isdir(ed_model_output)
    mkdir(ed_model_output)
end

# ------------------------------------------------------------------------------
# 1. CARGA DEL SISTEMA
# ------------------------------------------------------------------------------
file_path_static = joinpath(@__DIR__, "IEEE_14_Bus_Proyecto.m")
sys = System(file_path_static)
S_base = get_base_power(sys)

# Selección modo operación
tipo_contingencia = "line" # "line", "gen" o "normal"

# Elementos extra a incluir
include_in_grid = ["BESS"]   # agrega "CAPACITOR" más abajo, se dimensiona aparte
extra_descriptor = join(include_in_grid, "_")

# Ponderación 10%
λ_load = 1.10
cargas = collect(get_components(PowerLoad, sys))
for load in cargas
    set_active_power!(load, get_active_power(load) * λ_load)
    set_reactive_power!(load, get_reactive_power(load) * λ_load)
    set_max_active_power!(load, get_max_active_power(load) * λ_load)
    set_max_reactive_power!(load, get_max_reactive_power(load) * λ_load)
end

# ------------------------------------------------------------------------------
# 2. REEMPLAZO GEN-3 POR PLANTA FOTOVOLTAICA
# ------------------------------------------------------------------------------
gen_termico_a_retirar = get_component(ThermalStandard, sys, "gen-3")
max_active_power_gen_a_retirar = get_max_active_power(gen_termico_a_retirar)
bus_solar = get_bus(gen_termico_a_retirar)
remove_component!(sys, gen_termico_a_retirar)

cap_max_gen_solar = round(max_active_power_gen_a_retirar, digits=2)
set_bustype!(bus_solar, PowerSystems.ACBusTypes.PQ)
gen_solar = RenewableDispatch(
    name="gen-solar",
    available=true,
    bus=bus_solar,
    active_power=0.0,
    reactive_power=0.0,
    rating=cap_max_gen_solar,
    prime_mover_type=PrimeMovers.PVe,
    reactive_power_limits=(min=0, max=0),
    power_factor=1.0,
    operation_cost=TwoPartCost(VariableCost(0.0), 0.0),
    base_power=S_base)
add_component!(sys, gen_solar)

# ------------------------------------------------------------------------------
# 3. BESS — DIMENSIONAMIENTO CORREGIDO (35 MW / 70 MWh, Propuesta C)
# ------------------------------------------------------------------------------
for element in include_in_grid
    if element == "BESS"
        bess = GenericBattery(
            name = "BESS",
            available = true,
            bus = bus_solar,
            prime_mover_type = PrimeMovers.BA,

            # Energía: 70 MWh totales, inicia en 50% SoC (35 MWh)
            initial_energy = 35.0 / S_base,
            state_of_charge_limits = (
                min = 0.0 / S_base,
                max = 70.0 / S_base,
            ),

            # Potencia: 35 MW según Propuesta C del informe
            rating = 35.0 / S_base,
            active_power = 0.0 / S_base,

            input_active_power_limits  = (min = 0.0 / S_base, max = 35.0 / S_base),
            output_active_power_limits = (min = 0.0 / S_base, max = 35.0 / S_base),

            efficiency = (in = 0.95, out = 0.95),

            reactive_power = 0.0 / S_base,
            # Q no se optimiza en el ED (CopperPlatePowerModel no modela reactivos).
            # Este límite se usa más abajo, directamente en el flujo de potencia,
            # como el aporte reactivo rápido del inversor durante la contingencia.
            reactive_power_limits = (
                min = -15.0 / S_base,
                max =  15.0 / S_base,
            ),

            base_power = S_base,

            operation_cost = StorageManagementCost(
                variable = VariableCost(0.0),
                fixed = 0.0,
                start_up = 0.0,
                shut_down = 0.0,
                energy_shortage_cost = 1.0,
                energy_surplus_cost = 1.0,
            ),
        )
        add_component!(sys, bess)
    end
end

# ------------------------------------------------------------------------------
# 4. FUNCIONES DE COSTO — solo generadores térmicos
# ------------------------------------------------------------------------------
gens_termicos = sort!(collect(get_components(ThermalStandard, sys)), by=x -> get_name(x))

costos_fijos = [2100.0, 7200.0, 6250.0, 2000.0]
costos_variables = [(0.1, 10.0), (0.06, 7.0), (0.07, 8.0), (0.5, 60.0)]
for (i, g) in enumerate(gens_termicos)
    costo_cuadratico = VariableCost(costos_variables[i])
    costo_total = ThreePartCost(costo_cuadratico, costos_fijos[i], 0.0, 0.0)
    set_operation_cost!(g, costo_total)
end
println("\nCostos actualizados correctamente.")

for g in gens_termicos
    println("bus: $(get_number(get_bus(g))), gen_id: $(get_name(g))")
    println("Costo: $(get_operation_cost(g)), Límites: $(get_active_power_limits(g))")
end

# ------------------------------------------------------------------------------
# 5. PERFILES Y SERIES DE TIEMPO
# ------------------------------------------------------------------------------
start_time = DateTime("2024-01-01T00:00:00")
timestamps = [start_time + Hour(i) for i in 0:23]

ruta_perfiles = joinpath(@__DIR__, "perfiles_normalizados.csv")
df_perfiles = CSV.read(ruta_perfiles, DataFrame)

perfil_demanda_pu = df_perfiles.Demanda_normalizada
for load in get_components(PowerLoad, sys)
    ta = TimeArray(timestamps, perfil_demanda_pu)
    add_time_series!(sys, load, SingleTimeSeries(name="max_active_power", data=ta))
end

perfil_solar_pu = df_perfiles.Irradiancia_normalizada
ta_solar = TimeArray(timestamps, perfil_solar_pu)
add_time_series!(sys, gen_solar, SingleTimeSeries(name="max_active_power", data=ta_solar))

transform_single_time_series!(sys, 24, Hour(1))

# ------------------------------------------------------------------------------
# 6. OPTIMIZADOR — HiGHS no soporta MIQP (cuadrático + binario).
#    Si tu formulación de BESS agrega binarios de complementariedad
#    carga/descarga, junto con los costos cuadráticos de los térmicos,
#    el problema es MIQP. Se intenta primero con SCIP (sí soporta MIQP);
#    si no está disponible, cae a HiGHS (funcionará solo si tu formulación
#    de storage NO usa variables binarias).
# ------------------------------------------------------------------------------
optimizer = try
    using Pkg
    Pkg.add("SCIP")
    @eval using SCIP
    println("Usando SCIP (soporta MIQP).")
    optimizer_with_attributes(SCIP.Optimizer)
catch e
    println("SCIP no disponible ($e). Usando HiGHS.")
    println("Si el build!/solve! falla por 'quadratic' + 'integer', es necesario")
    println("cambiar a una formulación de BESS sin binarios (ver subtypes(PSI.AbstractStorageFormulation)).")
    optimizer_with_attributes(HiGHS.Optimizer)
end

# ------------------------------------------------------------------------------
# 7. PLANTILLA DE ED Y FORMULACIÓN DE LA BESS
# ------------------------------------------------------------------------------
template_ed = template_economic_dispatch()
set_network_model!(template_ed, NetworkModel(CopperPlatePowerModel, duals=[CopperPlateBalanceConstraint], use_slacks=true))

if "BESS" in include_in_grid
    # CHEQUEAR: si build!() falla pidiendo Reserve/AncillaryService, correr
    # `using PowerSimulations; const PSI = PowerSimulations; println(subtypes(PSI.AbstractStorageFormulation))`
    # y reemplazar por una formulación sin reservas.
    set_device_model!(template_ed, DeviceModel(GenericBattery, StorageDispatchWithReserves))
end

# ------------------------------------------------------------------------------
# 8. FUNCIÓN AUXILIAR: construir, resolver y extraer resultados de un ED
#    (se reutiliza para el ED base y para el ED de redespacho correctivo)
# ------------------------------------------------------------------------------
function resolver_ED(sys_input, template, opt, subdir_nombre)
    output_dir = joinpath(@__DIR__, subdir_nombre)
    if !isdir(output_dir)
        mkdir(output_dir)
    end

    modelo = DecisionModel(template, sys_input, optimizer=opt, horizon=24)
    println("\n[$subdir_nombre] Construyendo el modelo matemático...")
    build!(modelo, output_dir=output_dir)
    println("[$subdir_nombre] Resolviendo el despacho económico...")
    solve!(modelo)
    println("[$subdir_nombre] ¡Despacho resuelto!")

    res = ProblemResults(modelo)
    vars = read_variables(res)

    despacho_termico = vars["ActivePowerVariable__ThermalStandard"]
    despacho_solar = vars["ActivePowerVariable__RenewableDispatch"]
    despacho_p = innerjoin(despacho_termico, despacho_solar, on=:DateTime)

    if "BESS" in include_in_grid && haskey(vars, "ActivePowerInVariable__GenericBattery")
        p_in  = vars["ActivePowerInVariable__GenericBattery"]
        p_out = vars["ActivePowerOutVariable__GenericBattery"]
        despacho_BESS = DataFrame(
            DateTime = p_in.DateTime,
            Net_BESS = p_out[!, "BESS"] .- p_in[!, "BESS"]
        )
        despacho_p = innerjoin(despacho_p, despacho_BESS, on=:DateTime)
    end

    for col in names(despacho_p)[2:end]
        despacho_p[!, col] = [x < 1e-5 ? 0.0 : x for x in despacho_p[!, col]]
    end

    stats = read_optimizer_stats(res)
    duals = read_duals(res)
    lambda_pu = duals["CopperPlateBalanceConstraint__System"]
    lambda_mw = DataFrame(DateTime=lambda_pu.DateTime, Lambda_MW=lambda_pu[!, 2] ./ S_base)

    return despacho_p, stats, lambda_mw
end

# ------------------------------------------------------------------------------
# 9. ED BASE — sistema completo (gen-2 disponible todo el día)
# ------------------------------------------------------------------------------
despacho_p_base, stats_base, lambda_mw_base = resolver_ED(sys, template_ed, optimizer, "ED_model_base")

despacho_p_print = select(despacho_p_base, ["DateTime"; sort(names(despacho_p_base)[2:end])])
despacho_p_print.Demanda_Total_MW = sum.(eachrow(despacho_p_print[!, Not(:DateTime)]))
display(despacho_p_print)

println("\nCosto total minimizado (Caso Base): $(stats_base[1, :objective_value])")
display(lambda_mw_base)

# ------------------------------------------------------------------------------
# 10. ED DE REDESPACHO CORRECTIVO — solo si la contingencia es "gen"
#
#     Justificación (C-SCOPF, literatura ya citada en el informe): bajo
#     CopperPlatePowerModel la topología no afecta el ED, por lo que la
#     salida de la línea 2-3 no requiere redespacho a nivel de ED (el
#     problema de esa contingencia es puramente de tensión, se resuelve
#     en el flujo AC vía BESS + capacitor). La salida de gen-2 sí cambia
#     la capacidad disponible, así que si no se redespachan las unidades
#     sobrevivientes, todo el déficit lo termina absorbiendo la barra
#     slack sin respetar su Pmax (el problema que ya detectaste).
#
#     Simplificación pragmática por tiempo: se resuelve un segundo ED de
#     24 horas con gen-2 removido desde el inicio, y se usa esa tabla
#     SOLO para las horas 22:24 (21:00-23:00), empalmándola con la tabla
#     base para las horas 1:21 (que deben coincidir con el Caso Base,
#     como ya estableciste en la Sección 1.2). Ver el TODO más abajo
#     para la advertencia sobre continuidad del estado de carga de la BESS.
# ------------------------------------------------------------------------------
despacho_p_final = deepcopy(despacho_p_print)

if tipo_contingencia == "gen"
    sys_redespacho = deepcopy(sys)
    gen2_fuera = get_component(ThermalStandard, sys_redespacho, "gen-2")
    remove_component!(sys_redespacho, gen2_fuera)

    despacho_p_gen, stats_gen, lambda_mw_gen = resolver_ED(sys_redespacho, template_ed, optimizer, "ED_model_redespacho")

    # Empalme: horas 1-21 desde el ED base, horas 22-24 desde el ED correctivo
    for i in 22:24
        for col in names(despacho_p_gen)
            if col != "DateTime" && col in names(despacho_p_final)
                despacho_p_final[i, col] = despacho_p_gen[i, col]
            end
        end
        # gen-2 no existe en la tabla correctiva -> queda en 0 para esas horas
        if "gen-2" in names(despacho_p_final)
            despacho_p_final[i, "gen-2"] = 0.0
        end
    end

    despacho_p_final.Demanda_Total_MW = sum.(eachrow(despacho_p_final[!, Not([:DateTime, :Demanda_Total_MW])]))

    # TODO: verificar continuidad de la BESS en la hora 21 -> comparar
    # despacho_p_print[21, "Net_BESS"] (o el SoC si lo extraes aparte)
    # contra el valor correspondiente en despacho_p_gen. Si difieren mucho,
    # declarar la aproximación en el informe como simplificación consciente.
    println("\nRedespacho correctivo aplicado para horas 22-24 (contingencia gen-2).")
    println("Costo total ED correctivo (referencial): $(stats_gen[1, :objective_value])")
end

display(despacho_p_final)

### GUARDAR INFO PARA ANÁLISIS ###
tablas_path = "Tablas_Resultados_ED_2"
mkpath(tablas_path)
CSV.write(joinpath(tablas_path, "1_despachos_generacion_$(extra_descriptor)_$(tipo_contingencia).csv"), despacho_p_final)

demanda_base_total_mw = sum(get_active_power(load) for load in get_components(PowerLoad, sys)) * S_base
demanda_real_mw = demanda_base_total_mw .* df_perfiles.Demanda_normalizada
df_demanda = DataFrame(DateTime = timestamps, Demanda_Total_MW = demanda_real_mw)
CSV.write(joinpath(tablas_path, "2_demanda_total_real_$(extra_descriptor).csv"), df_demanda)

df_comparacion = DataFrame(
    DateTime      = timestamps,
    Generacion_MW = despacho_p_final.Demanda_Total_MW,
    Demanda_MW    = demanda_real_mw,
    Diferencia_MW = despacho_p_final.Demanda_Total_MW .- demanda_real_mw
)
display(df_comparacion)
CSV.write(joinpath(tablas_path, "3_comparacion_gen_dem_$(extra_descriptor).csv"), df_comparacion)
CSV.write(joinpath(tablas_path, "4_costo_marginal_$(extra_descriptor).csv"), lambda_mw_base)

# ==============================================================================
# 11. FLUJO DE POTENCIA AC
# ==============================================================================
println("Flujo potencia iniciado")

sys_flujo = deepcopy(sys)
ac_pf_solver = ACPowerFlow(check_reactive_power_limits = true)

resultados_voltaje = DataFrame(Hora = 1:24)
barras = sort(collect(get_components(Bus, sys_flujo)), by = x -> get_number(x))
for b in barras
    resultados_voltaje[!, "Barra_$(get_number(b))"] = zeros(Float64, 24)
end

base_P_load = Dict(get_name(l) => get_active_power(l) for l in get_components(PowerLoad, sys_flujo))
base_Q_load = Dict(get_name(l) => get_reactive_power(l) for l in get_components(PowerLoad, sys_flujo))
gens_termicos_flujo = sort!(collect(get_components(ThermalStandard, sys_flujo)), by=x -> get_name(x))
gen_solar_flujo = get_component(RenewableDispatch, sys_flujo, "gen-solar")
bess_flujo = "BESS" in include_in_grid ? get_component(GenericBattery, sys_flujo, "BESS") : nothing

# Tamaño de capacitor a usar (se define en la Sección 12; si aún no se ha
# dimensionado, se deja en 0 -- correr primero sin capacitor, tomar el
# Q_optimo resultante y volver a correr este bloque con ese valor).
Q_capacitor_mvar = 0.0  # <- reemplazar por Q_optimo una vez dimensionado (Sección 12)

function agregar_capacitor!(system, bus, Q_mvar)
    B_pu = Q_mvar / get_base_power(system)  # CHEQUEAR signo: si el voltaje baja al agregarlo, invertir el signo
    cap = FixedAdmittance(
        name = "capacitor_barra3",
        available = true,
        bus = bus,
        Y = Complex(0.0, B_pu),   # CHEQUEAR: nombre de campo con fieldnames(FixedAdmittance)
    )
    add_component!(system, cap)
    return cap
end

if Q_capacitor_mvar > 0.0
    bus3_flujo = get_component(Bus, sys_flujo, "3")
    agregar_capacitor!(sys_flujo, bus3_flujo, Q_capacitor_mvar)
end

analisis_compensacion = DataFrame(Hora = 1:24)
for g in gens_termicos_flujo
    analisis_compensacion[!, "Dev_MW_" * get_name(g)] = zeros(Float64, 24)
end

despacho_modo = DataFrame(Hora = 0:23)
for nombre in ["gen-1", "gen-2", "gen-4", "gen-5", "gen-solar"]
    despacho_modo[!, nombre] = zeros(Float64, 24)
end
despacho_modo[!, "Total_Generacion_MW"] = zeros(Float64, 24)
despacho_modo[!, "Modo"] = fill(tipo_contingencia, 24)
if "BESS" in include_in_grid
    despacho_modo[!, "BESS_MW"] = zeros(Float64, 24)
end

for i in 1:24
    if i == 22
        println("\n\nSon las 21:00\n")
        if tipo_contingencia == "line"
            line_2_3 = get_component(ACBranch, sys_flujo, "2-3-i_3")
            remove_component!(sys_flujo, line_2_3)
            println("Contingencia aplicada: salida linea 2-3\n\n")
        elseif tipo_contingencia == "gen"
            gen_barra2 = get_component(ThermalStandard, sys_flujo, "gen-2")
            remove_component!(sys_flujo, gen_barra2)
            global gens_termicos_flujo = sort!(collect(get_components(ThermalStandard, sys_flujo)), by=x -> get_name(x))
            println("Contingencia aplicada: caida generador barra 2\n\n")
        elseif tipo_contingencia == "normal"
            println("Modo de operación normal\n\n")
        else
            global tipo_contingencia = "normal"
            println("Modo de operación no reconocido, se utiliza modo normal por defecto\n\n")
        end
    end

    factor_demanda = df_perfiles.Demanda_normalizada[i]
    for l in get_components(PowerLoad, sys_flujo)
        set_active_power!(l, base_P_load[get_name(l)] * factor_demanda)
        set_reactive_power!(l, base_Q_load[get_name(l)] * factor_demanda)
    end

    factor_solar = df_perfiles.Irradiancia_normalizada[i]
    set_active_power!(gen_solar_flujo, cap_max_gen_solar * factor_solar)

    for g in gens_termicos_flujo
        nombre_gen = get_name(g)
        p_despacho_mw = despacho_p_final[i, nombre_gen]
        set_active_power!(g, p_despacho_mw / S_base)
    end

    # --- BESS: P viene del ED (o del redespacho correctivo si aplica),
    #     Q se fija directo aquí porque el ED en CopperPlate no la optimiza ---
    if !isnothing(bess_flujo)
        p_bess_mw = "Net_BESS" in names(despacho_p_final) ? despacho_p_final[i, "Net_BESS"] : 0.0
        set_active_power!(bess_flujo, p_bess_mw / S_base)

        if i >= 22
            # Soporte reactivo dinámico máximo durante la contingencia
            set_reactive_power!(bess_flujo, 15.0 / S_base)
        else
            set_reactive_power!(bess_flujo, 0.0)
        end
        despacho_modo[i, "BESS_MW"] = p_bess_mw
    end

    res_temp = PowerFlows.solve_powerflow(ac_pf_solver, sys_flujo)
    if isa(res_temp, Dict)
        df_temp = res_temp["bus_results"]

        gen1_mw = gen2_mw = gen4_mw = gen5_mw = genfv_mw = 0.0
        for row in eachrow(df_temp)
            bus_num = row.bus_number
            if bus_num == 1; gen1_mw = row.P_gen
            elseif bus_num == 2; gen2_mw = row.P_gen
            elseif bus_num == 3; genfv_mw = row.P_gen
            elseif bus_num == 6; gen4_mw = row.P_gen
            elseif bus_num == 8; gen5_mw = row.P_gen
            end
        end

        if tipo_contingencia == "gen" && i >= 22
            gen2_mw = 0.0
        end

        despacho_modo[i, "gen-1"] = gen1_mw
        despacho_modo[i, "gen-2"] = gen2_mw
        despacho_modo[i, "gen-4"] = gen4_mw
        despacho_modo[i, "gen-5"] = gen5_mw
        despacho_modo[i, "gen-solar"] = genfv_mw
        despacho_modo[i, "Total_Generacion_MW"] = gen1_mw + gen2_mw + gen4_mw + gen5_mw + genfv_mw

        for g in gens_termicos_flujo
            nombre = get_name(g)
            num_bus = get_number(get_bus(g))
            p_ordenada = despacho_p_final[i, nombre]
            p_real_pf_mw = df_temp[df_temp.bus_number .== num_bus, :P_gen][1]
            desviacion = p_real_pf_mw - p_ordenada
            analisis_compensacion[i, "Dev_MW_" * nombre] = abs(desviacion) < 1e-5 ? 0.0 : desviacion
        end

        for b in barras
            num_bar = get_number(b)
            v_actual = df_temp[df_temp.bus_number .== num_bar, :Vm][1]
            resultados_voltaje[i, "Barra_$num_bar"] = v_actual
        end
    else
        println("OJITO PIOJO: El flujo de potencia no convergió en la Hora $(i-1)")
    end
end

println("\nFlujos de potencia exitosos")
display(resultados_voltaje)

CSV.write(joinpath(tablas_path, "5_perfiles_voltaje_modo_$(extra_descriptor)_$(tipo_contingencia).csv"), resultados_voltaje)
CSV.write(joinpath(tablas_path, "7_despacho_generacion_modo_$(extra_descriptor)_$(tipo_contingencia).csv"), despacho_modo)

println("\nVerificación norma técnica de voltajes [0.95, 1.05] pu:")
df_voltajes_largo = stack(resultados_voltaje, Not(:Hora), variable_name=:Barra, value_name=:Vm)
violaciones = filter(r -> r.Vm < 0.95 || r.Vm > 1.05, df_voltajes_largo)
if nrow(violaciones) == 0
    println("✓ Todos los voltajes se mantienen dentro del rango [0.95, 1.05] pu.")
else
    println("⚠ VIOLACIONES DE VOLTAJE ENCONTRADAS:")
    display(violaciones)
end
CSV.write(joinpath(tablas_path, "5b_violaciones_voltaje_modo_$(extra_descriptor)_$(tipo_contingencia).csv"), violaciones)

display(analisis_compensacion)
CSV.write(joinpath(tablas_path, "6_analisis_compensacion_$(extra_descriptor).csv"), analisis_compensacion)

# ==============================================================================
# 12. DIMENSIONAMIENTO DEL CAPACITOR — búsqueda incremental
#
#     Se corre DESPUÉS de tener BESS + redespacho funcionando, porque su
#     resultado depende de ambos (el capacitor solo tiene que cubrir lo
#     que quede pendiente tras esas dos medidas). Usa el estado de
#     sys_flujo ya con la contingencia aplicada (después del loop de
#     arriba) como punto de partida para cada prueba.
# ==============================================================================
Q_candidatos = 5.0:5.0:80.0
Q_optimo = nothing

for Q_mvar in Q_candidatos
    voltajes_min_por_hora = Float64[]

    for i in 22:24
        sys_prueba = deepcopy(sys_flujo)
        bus3_prueba = get_component(Bus, sys_prueba, "3")
        agregar_capacitor!(sys_prueba, bus3_prueba, Q_mvar)

        factor_demanda = df_perfiles.Demanda_normalizada[i]
        for l in get_components(PowerLoad, sys_prueba)
            set_active_power!(l, base_P_load[get_name(l)] * factor_demanda)
            set_reactive_power!(l, base_Q_load[get_name(l)] * factor_demanda)
        end

        factor_solar = df_perfiles.Irradiancia_normalizada[i]
        gen_solar_prueba = get_component(RenewableDispatch, sys_prueba, "gen-solar")
        set_active_power!(gen_solar_prueba, cap_max_gen_solar * factor_solar)

        gens_termicos_prueba = sort!(collect(get_components(ThermalStandard, sys_prueba)), by=x -> get_name(x))
        for g in gens_termicos_prueba
            nombre_gen = get_name(g)
            if nombre_gen in names(despacho_p_final)
                set_active_power!(g, despacho_p_final[i, nombre_gen] / S_base)
            end
        end

        if "BESS" in include_in_grid
            bess_prueba = get_component(GenericBattery, sys_prueba, "BESS")
            if !isnothing(bess_prueba)
                p_bess_mw = "Net_BESS" in names(despacho_p_final) ? despacho_p_final[i, "Net_BESS"] : 0.0
                set_active_power!(bess_prueba, p_bess_mw / S_base)
                set_reactive_power!(bess_prueba, 15.0 / S_base)
            end
        end

        resultado = PowerFlows.solve_powerflow(ac_pf_solver, sys_prueba)
        if isa(resultado, Dict)
            push!(voltajes_min_por_hora, minimum(resultado["bus_results"].Vm))
        else
            push!(voltajes_min_por_hora, NaN)
        end
    end

    if any(isnan, voltajes_min_por_hora)
        println("Q = $Q_mvar MVAR -> flujo no convergió en alguna hora")
        continue
    end

    v_min_global = minimum(voltajes_min_por_hora)
    println("Q = $Q_mvar MVAR -> V_min entre 21:00-23:00 = $(round(v_min_global, digits=4)) pu")

    if v_min_global >= 0.95
        global Q_optimo = Q_mvar
        println("✓ Tamaño mínimo de capacitor encontrado: $Q_mvar MVAR")
        break
    end
end

if isnothing(Q_optimo)
    println("\n⚠ Ningún tamaño evaluado en el rango 5-80 MVAR logra 0.95 pu por sí solo.")
    println("Esto es consistente con la limitación V² señalada en el informe: el")
    println("capacitor complementa el aporte dinámico de la BESS, no lo reemplaza.")
    println("Considera ampliar el rango de búsqueda o revisar el tamaño de la BESS.")
else
    println("\nRecuerda volver a la Sección 11 y fijar Q_capacitor_mvar = $Q_optimo")
    println("para dejar el capacitor incorporado en el flujo de potencia final.")
end