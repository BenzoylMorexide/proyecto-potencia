using PowerSystems, PowerSimulations, PowerFlows
using Dates, TimeSeries
# using Ipopt
using Ipopt, HiGHS, Juniper
using CSV, DataFrames, Plots
using StorageSystemsSimulations # v0.9.0

# Carpeta para guardar el modelo
ed_model_output = joinpath(@__DIR__, "ED_model")
if !isdir(ed_model_output)
    mkdir(ed_model_output)
end

# Carga del sistema
file_path_static = joinpath(@__DIR__, "IEEE_14_Bus_Proyecto.m")
sys = System(file_path_static)
S_base = get_base_power(sys)

# Seleccion modo operación
tipos_contingencia = ["line", "gen", "normal"]
# line para caida de linea 2-3; gen para caída de gen síncrono en barra 2; normal para modo normal

# seleccionar elementos extras a ocupar
include_in_grid = ["BESS"] # "BESS", "statcom"
# parámetros de cada elemento en su respectiva descripción

# Margen para el slack en flujo AC
margen_gen1 = 0.9  # deja 10% de holgura

# Candidatos de ubicación para el STATCOM (se recorren todos si "statcom" está activo)
barras = [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]

extra_descriptor = join(include_in_grid, "_")

#Ponderación 10% 
λ_load = 1.10
cargas = collect(get_components(PowerLoad, sys));
for load in cargas
    set_active_power!(load, get_active_power(load) * λ_load)
    set_reactive_power!(load, get_reactive_power(load) * λ_load)
    set_max_active_power!(load, get_max_active_power(load) * λ_load)
    set_max_reactive_power!(load, get_max_reactive_power(load) * λ_load)
end

# dar margen a gen_1 para que, al ser usado como slack, cuando difiera l apotencia del E igual quede dentro del margen
gen1 = get_component(ThermalStandard, sys, "gen-1")
limites_originales_gen1 = get_active_power_limits(gen1)

nuevos_limites_gen1 = (
    min = limites_originales_gen1.min,
    max = limites_originales_gen1.max * margen_gen1
)
set_active_power_limits!(gen1, nuevos_limites_gen1)

# Reemplazo gen3
gen_termico_a_retirar = get_component(ThermalStandard, sys, "gen-3")
max_active_power_gen_a_retirar = get_max_active_power(gen_termico_a_retirar)
bus_solar = get_bus(gen_termico_a_retirar)
remove_component!(sys, gen_termico_a_retirar)

# Capacidad del panel solar
cap_max_gen_solar = round(max_active_power_gen_a_retirar, digits=2)
# Segun enunciado, como no tenemos capacidad de regular Q se convierte a PQ
set_bustype!(bus_solar, PowerSystems.ACBusTypes.PQ)
gen_solar = RenewableDispatch(
    name="gen-solar",
    available=true,
    bus=bus_solar,
    active_power=0.0,
    reactive_power=0.0,
    rating=cap_max_gen_solar, # asegura que el reemplazo de tecnología mantenga la capacidad de generación
    prime_mover_type=PrimeMovers.PVe,
    reactive_power_limits=(min=0, max=0), # está capacitado para regular reactivos/ AJUSTE, NO ESTA CAPACITADO SEGUN ENUNCIADO
    power_factor=1.0,
    operation_cost=TwoPartCost(VariableCost(0.0), 0.0), # Costo variable 0
    base_power=S_base)
add_component!(sys, gen_solar)

for element in include_in_grid
    if element == "BESS"
        max_capacity_BESS = 180 # MWh
        bess = GenericBattery(
            name = "BESS",
            available = true,
            bus = bus_solar, # BESS puesto en bus solar por defecto

            prime_mover_type = PrimeMovers.BA, # Batería estándard

            # Energía en MWh
            initial_energy = 90.0/S_base,

            state_of_charge_limits = (
                min = max_capacity_BESS*0.05/S_base,
                max = max_capacity_BESS*0.95/S_base,
            ),

            # Potencia (MW)
            rating = 60.0/S_base, # equivalente a potencia máxima
            active_power = 0.0/S_base, # potencia actual

            input_active_power_limits = (
                min = 0.0/S_base,
                max = 60.0/S_base,
            ),

            output_active_power_limits = (
                min = 0.0/S_base,
                max = 60.0/S_base,
            ),

            efficiency = (
                in = 0.96,
                out = 0.96,
            ),

            reactive_power = 0.0/S_base,
            reactive_power_limits = (
                min = -20.0/S_base,
                max = 20.0/S_base,
            ),# dentro de un margen de f.p. de 0.95

            base_power = S_base,

            # optimización para costo de almacenamiento
            operation_cost = StorageManagementCost(
                variable = VariableCost(0.0), # Precio por MWh
                fixed = 0.0,    # costo fijo
                start_up = 0.0, # costo de encendido
                shut_down = 0.0,    #costo de apagado
                energy_shortage_cost = 100.0, # Multa por terminar la simulación con menos energía que la inicial
                energy_surplus_cost = 100.0, # Multa por terminar la simulación con más energía que la inicial
                # las multas anteriores es para que no se aproveche de la energía inicial de las baterías para compensar el limitado horizonte de simulación
                # se trabajará con un valor que logre un estado relativamente constante en operación normal, pero que no restringa bajo operación con contingencia
            ),
        )
        add_component!(sys, bess)
    end
end

#Funciones de costo: solo asignamos a los generadores térmicos
gens_termicos = sort!(collect(get_components(ThermalStandard, sys)), by=x -> get_name(x))

# SE CAMBIARON SEGUN ENUNCIADO
costos_fijos = [2100.0, 7200.0, 6250.0, 2000.0] # a
costos_variables = [(0.1, 10.0), (0.06, 7.0), (0.07, 8.0), (0.5, 60.0)] # (c,b)
for (i, g) in enumerate(gens_termicos)
    costo_cuadratico = VariableCost(costos_variables[i])
    costo_total = ThreePartCost(costo_cuadratico, costos_fijos[i], 0.0, 0.0)
    set_operation_cost!(g, costo_total)
end
println("\nCostos actualizados correctamente.")

# Imprimimos información de los generadores síncronos
for g in gens_termicos
    println("bus: $(get_number(get_bus(g))), gen_id: $(get_name(g))")
    println("Costo: $(get_operation_cost(g)), Límites: $(get_active_power_limits(g))")
end

#ED
start_time = DateTime("2024-01-01T00:00:00") # "yyyy-mm-dd"
timestamps = [start_time + Hour(i) for i in 0:23]

# Carga de perfiles desde el archivo CSV
ruta_perfiles = joinpath(@__DIR__, "perfiles_normalizados.csv")
df_perfiles = CSV.read(ruta_perfiles, DataFrame)

# Perfil de demanda normalizado aplicado a todas las cargas del sistema:
perfil_demanda_pu = df_perfiles.Demanda_normalizada
for load in get_components(PowerLoad, sys)
    ta = TimeArray(timestamps, perfil_demanda_pu)
    add_time_series!(sys, load, SingleTimeSeries(name="max_active_power", data=ta))
end

# Perfil de irradiancia solar normalizado aplicado a la generación fotovoltaica:
perfil_solar_pu = df_perfiles.Irradiancia_normalizada
ta_solar = TimeArray(timestamps, perfil_solar_pu)
add_time_series!(sys, gen_solar, SingleTimeSeries(name="max_active_power", data=ta_solar))

# Transformamos las TimeSeries de un solo escenario (SingleTimeSeries) a Deterministic para DecisionModel
transform_single_time_series!(sys, 24, Hour(1)) # (sys, horizonte temporal, resolución temporal)

# Plantilla de ED
template_ed = template_economic_dispatch()
set_network_model!(template_ed, NetworkModel(CopperPlatePowerModel, duals=[CopperPlateBalanceConstraint], use_slacks=true))

if "BESS" in include_in_grid
    set_device_model!(template_ed, DeviceModel(GenericBattery, StorageDispatchWithReserves))
end

# Optimizador y DecisionModel
optimizer = optimizer_with_attributes(
    Juniper.Optimizer,
    "nl_solver" => optimizer_with_attributes(Ipopt.Optimizer, "print_level" => 0),
    "mip_solver" => optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
)
# en el output del solver
modelo_ed = DecisionModel(template_ed, sys, optimizer=optimizer, horizon=24)

# Construcción del modelo y resolver el ED
println("\nConstruyendo el modelo matemático...")
build!(modelo_ed, output_dir=ed_model_output)
println("\nResolviendo el despacho económico...")
solve!(modelo_ed)
println("\n¡Despacho resuelto exitosamente!")

# Extracción de los resultados
res = ProblemResults(modelo_ed)
vars = read_variables(res)
println("\nResultados para variables de decisión (MW):")
despacho_termico = vars["ActivePowerVariable__ThermalStandard"]
despacho_solar = vars["ActivePowerVariable__RenewableDispatch"]
despacho_p = innerjoin(despacho_termico, despacho_solar, on=:DateTime)

# Cosas agregadas
if "BESS" in include_in_grid
    p_in  = vars["ActivePowerInVariable__GenericBattery"]
    p_out = vars["ActivePowerOutVariable__GenericBattery"]

    despacho_BESS = DataFrame(
        DateTime = p_in.DateTime,
        Net_BESS = p_out[!, "BESS"] .- p_in[!, "BESS"]
    )
    despacho_p = innerjoin(despacho_p, despacho_BESS, on=:DateTime)
end

despacho_p_print = select(despacho_p, ["DateTime"; sort(names(despacho_p)[2:end])])
display(despacho_p_print)
println("\nResultados para función objetivo - costos minimizados:")
stats = read_optimizer_stats(res)
println(stats[1, :objective_value])
println("\nResultados para variables duales - precio de la energía (\$/MWh):")
duals = read_duals(res)
# La restricción de balance de potencia está formulada en pu, su dual está en $/pu.
lambda_pu = duals["CopperPlateBalanceConstraint__System"]

# Las salidas de este código deberán ser consideradas como los setpoints de potencia activa a emplear en
# la resolución de los flujos de potencia.

### GUARDAR INFO PARA ANALISIS ###
tablas_path = "Tablas_Resultados_ED_2"
mkpath(tablas_path)

# Limpieza de valores pequeños negativos antes de exportar
for col in names(despacho_p_print)[2:end]
    if col == "Net_BESS"
        # signed quantity: only clean genuine near-zero noise, keep sign
        despacho_p_print[!, col] = [abs(x) < 1e-5 ? 0.0 : x for x in despacho_p_print[!, col]]
    else
        # generation columns: always non-negative, clamp tiny negative noise to 0
        despacho_p_print[!, col] = [x < 1e-5 ? 0.0 : x for x in despacho_p_print[!, col]]
    end
end


# Los puntos de despacho de potencia activa (MW) de todas las unidades generadoras en cada hora, otorgados por los EDs.
# Aprovecho de agregar una nueva columna con la suma de generacion por cada fila.

despacho_p_print.Demanda_Total_MW = sum.(eachrow(despacho_p_print[!, 2:end]))

# El costo total minimizado al final del d´ıa de ma˜nana, otorgado por los EDs.
# Resultados para función objetivo - costos minimizados:
#  VALOR OBTENIDO EN CONSOLA:  31147.352583930755
# La evolucion de la demanda total (MW) del sistema en cada hora del dia, esclareciendo
# si es o no satisfecha con los despachos calculados en 1. Identifique el o los horarios de
# mayor demanda.



CSV.write(joinpath(tablas_path, "1_despachos_generacion_$(extra_descriptor).csv"), despacho_p_print)

demanda_base_total_mw = sum(get_active_power(load) for load in get_components(PowerLoad, sys)) * S_base
demanda_real_mw = demanda_base_total_mw .* df_perfiles.Demanda_normalizada
df_demanda = DataFrame(
    DateTime = timestamps,
    Demanda_Total_MW = demanda_real_mw
)
CSV.write(joinpath(tablas_path, "2_demanda_total_real_$(extra_descriptor).csv"), df_demanda)


# generación total despachada vs demanda real por hora
df_comparacion = DataFrame(
    DateTime      = timestamps,
    Generacion_MW = despacho_p_print.Demanda_Total_MW,
    Demanda_MW    = demanda_real_mw,
    Diferencia_MW = despacho_p_print.Demanda_Total_MW .- demanda_real_mw
)
println("\nComparación Generación vs Demanda (MW) por hora:")
display(df_comparacion)
idx_max_dem = argmax(demanda_real_mw)
println("Hora de mayor demanda: $(timestamps[idx_max_dem]) → $(round(demanda_real_mw[idx_max_dem], digits=2)) MW")
CSV.write(joinpath(tablas_path, "3_comparacion_gen_dem_$(extra_descriptor).csv"), df_comparacion)


### PARTE DE FLUJO DE POTENCIA PA HACER LA 5. ###

println("FLujo potencia iniciado")

function correr_flujo_potencia(sys, contingencia; bus_statcom_number=nothing)

    sys_flujo = deepcopy(sys)

    if "statcom" in include_in_grid
        extra_descriptor_AC = extra_descriptor*"_barra_$(bus_statcom_number)"
    else
        extra_descriptor_AC = extra_descriptor
    end


    nombre_statcom = nothing
    q_statcom_mvar = nothing



    if "statcom" in include_in_grid
        bus_statcom_flujo = only(get_buses(sys_flujo, Set([bus_statcom_number])))

        Q_statcom_mvar     = 30.0
        v_setpoint_statcom = 1.0

        set_bustype!(bus_statcom_flujo, PowerSystems.ACBusTypes.PV)
        set_magnitude!(bus_statcom_flujo, v_setpoint_statcom)

        nombre_statcom = "STATCOM_Barra$(bus_statcom_number)"

        statcom = ThermalStandard(
            name      = nombre_statcom,
            available = true,
            status    = true,
            bus       = bus_statcom_flujo,

            active_power   = 0.0,
            reactive_power = 0.0,
            rating = Q_statcom_mvar / S_base,
            ramp_limits = nothing,

            active_power_limits = (min = 0.0, max = 0.0),
            reactive_power_limits = (
                min = -Q_statcom_mvar / S_base,
                max =  Q_statcom_mvar / S_base,
            ),

            operation_cost   = ThreePartCost(VariableCost(0.0), 0.0, 0.0, 0.0),
            base_power       = S_base,
            prime_mover_type = PrimeMovers.OT,
            fuel             = ThermalFuels.OTHER,
        )
        add_component!(sys_flujo, statcom)
        q_statcom_mvar = zeros(Float64, 24)
    end





    ac_pf_solver = ACPowerFlow(check_reactive_power_limits = true)

    resultados_voltaje = DataFrame(Hora = 1:24)

    barras_bus = sort(collect(get_components(Bus, sys_flujo)), by = x -> get_number(x))
    for b in barras_bus
        resultados_voltaje[!, "Barra_$(get_number(b))"] = zeros(Float64, 24)
    end

    base_P_load = Dict(get_name(l) => get_active_power(l) for l in get_components(PowerLoad, sys_flujo))
    base_Q_load = Dict(get_name(l) => get_reactive_power(l) for l in get_components(PowerLoad, sys_flujo))

    gens_termicos_flujo = sort!(
        collect(get_components(g -> get_name(g) != nombre_statcom, ThermalStandard, sys_flujo)),
        by = x -> get_name(x)
    )

    gen_solar_flujo = get_component(RenewableDispatch, sys_flujo, "gen-solar")

    bess_flujo = nothing
    if "BESS" in include_in_grid
        bess_flujo = get_component(GenericBattery, sys_flujo, "BESS")
    end

    # Crear tabla para comprobar la desviación de potencia activa de TODOS los generadores
    analisis_compensacion = DataFrame(Hora = 1:24)
    for g in gens_termicos_flujo
        analisis_compensacion[!, "Dev_MW_" * get_name(g)] = zeros(Float64, 24)
    end

    # Tabla de despacho por modo
    despacho_modo = DataFrame(Hora = 0:23)

    tipos_despachos = ["gen-1", "gen-2", "gen-4", "gen-5", "gen-solar"]
    if "BESS" in include_in_grid
        push!(tipos_despachos, "BESS")
    end

    for nombre in tipos_despachos
        despacho_modo[!, nombre] = zeros(Float64, 24)
    end

    despacho_modo[!, "Total_Generacion_MW"] = zeros(Float64, 24)
    despacho_modo[!, "Modo"] = fill(contingencia, 24)

    net_bess_mw = 0.0

    # en el loop de aca abajo se corre para cada hora un flujo. Para eso, primero
    # se actualizan los valores de las demandas para esa hora según el .csv entregado
    for i in 1:24
        if i == 22
            println("\n\nSon las 21:00 (barra=$(bus_statcom_number), contingencia=$(contingencia))\n")
            if contingencia == "line"
                line_2_3 = get_component(ACBranch, sys_flujo, "2-3-i_3")
                remove_component!(sys_flujo, line_2_3)
                println("Contingencia aplicada: salida linea 2-3\n\n")
            elseif contingencia == "gen"
                gen_barra2 = get_component(ThermalStandard, sys, "gen-2")
                remove_component!(sys_flujo, gen_barra2)
                gens_termicos_flujo = sort!(
                    collect(get_components(g -> get_name(g) != nombre_statcom, ThermalStandard, sys_flujo)),
                    by = x -> get_name(x)
                )
                println("Contingencia aplicada: caida generador barra 2\n\n")
            elseif contingencia == "normal"
                println("Modo de operación normal\n\n")
            else
                contingencia = "normal"
                println("Modo de operación no reconocido, se utiliza modo normal por defecto\n\n")
            end
        end

        factor_demanda = df_perfiles.Demanda_normalizada[i]
        for l in get_components(PowerLoad, sys_flujo)
            set_active_power!(l, base_P_load[get_name(l)] * factor_demanda)
            set_reactive_power!(l, base_Q_load[get_name(l)] * factor_demanda)
        end

        # lo mismo de antes pero ahora actualizamos para cada hora la generacion
        # de la planta solar segun el .csv entregado de irradiancia.
        factor_solar = df_perfiles.Irradiancia_normalizada[i]
        set_active_power!(gen_solar_flujo, cap_max_gen_solar * factor_solar)
        if "BESS" in include_in_grid
            net_bess_mw = despacho_p_print[i, "Net_BESS"]
            set_active_power!(bess_flujo, net_bess_mw / S_base)
        end

        for g in gens_termicos_flujo
            nombre_gen = get_name(g)
            p_despacho_mw = despacho_p_print[i, nombre_gen]
            set_active_power!(g, p_despacho_mw / S_base)
        end

        res_temp = PowerFlows.solve_powerflow(ac_pf_solver, sys_flujo)
        if isa(res_temp, Dict)
            df_temp = res_temp["bus_results"]

            if "statcom" in include_in_grid
                q_bus_statcom = df_temp[df_temp.bus_number .== bus_statcom_number, :Q_gen][1]
                q_statcom_mvar[i] = q_bus_statcom * S_base
            end

            gen1_mw = 0.0
            gen2_mw = 0.0
            gen4_mw = 0.0
            gen5_mw = 0.0
            genfv_mw = 0.0

            for row in eachrow(df_temp)
                bus_num = row.bus_number

                if bus_num == 1
                    gen1_mw = row.P_gen
                elseif bus_num == 2
                    gen2_mw = row.P_gen
                elseif bus_num == 3
                    genfv_mw = row.P_gen - (("BESS" in include_in_grid) ? net_bess_mw : 0.0)
                elseif bus_num == 6
                    gen4_mw = row.P_gen
                elseif bus_num == 8
                    gen5_mw = row.P_gen
                end
            end


            # Si el modo es caída del generador 2 y ya ocurrió la contingencia,
            # se deja explícitamente gen-2 en cero en la tabla.
            if contingencia == "gen" && i >= 22
                gen2_mw = 0.0
            end

            despacho_modo[i, "gen-1"] = gen1_mw
            despacho_modo[i, "gen-2"] = gen2_mw
            despacho_modo[i, "gen-4"] = gen4_mw
            despacho_modo[i, "gen-5"] = gen5_mw
            despacho_modo[i, "gen-solar"] = genfv_mw

            if "BESS" in include_in_grid
                despacho_modo[i, "BESS"] = net_bess_mw
            end

            despacho_modo[i, "Total_Generacion_MW"] =
                gen1_mw + gen2_mw + gen4_mw + gen5_mw + genfv_mw + (("BESS" in include_in_grid) ? net_bess_mw : 0.0)

            for g in gens_termicos_flujo
                nombre = get_name(g)
                num_bus = get_number(get_bus(g))

                p_ordenada = despacho_p_print[i, nombre]
                p_real_pf_mw = df_temp[df_temp.bus_number .== num_bus, :P_gen][1]
                desviacion = p_real_pf_mw - p_ordenada

                # mandar a cero los números muy chicos
                analisis_compensacion[i, "Dev_MW_" * nombre] = abs(desviacion) < 1e-5 ? 0.0 : desviacion
            end

            for b in barras_bus
                num_bar = get_number(b)
                # Buscamos el voltaje de esta barra en el DataFrame de resultados
                v_actual = df_temp[df_temp.bus_number .== num_bar, :Vm][1]
                resultados_voltaje[i, "Barra_$num_bar"] = v_actual
            end
        else
            println("OJITO PIOJO: El flujo de potencia no convergió en la Hora $(i-1) (barra=$(bus_statcom_number), contingencia=$(contingencia))") # XDDDDDDDDD
        end
    end

    println("\nFlujos de potencia Exitosos (barra=$(bus_statcom_number), contingencia=$(contingencia))")
    display(resultados_voltaje)

    CSV.write(joinpath(tablas_path, "5_perfiles_voltaje_modo_$(extra_descriptor_AC)_$(contingencia).csv"), resultados_voltaje)

    CSV.write(
        joinpath(tablas_path, "7_despacho_generacion_modo_$(extra_descriptor_AC)_$(contingencia).csv"),
        despacho_modo
    )

    # Verificación norma técnica: 0.95 <= |V| <= 1.05 pu
    println("\nVerificación norma técnica de voltajes [0.95, 1.05] pu:")
    df_voltajes_largo = stack(resultados_voltaje, Not(:Hora), variable_name=:Barra, value_name=:Vm)
    violaciones = filter(r -> r.Vm < 0.95 || r.Vm > 1.05, df_voltajes_largo)
    if nrow(violaciones) == 0
        println("✓ Todos los voltajes se mantienen dentro del rango [0.95, 1.05] pu.")
    else
        println("⚠ VIOLACIONES DE VOLTAJE ENCONTRADAS:")
        display(violaciones)
    end
    CSV.write(joinpath(tablas_path, "5b_violaciones_voltaje_modo_$(extra_descriptor_AC)_$(contingencia).csv"), violaciones)

    display(analisis_compensacion)
    CSV.write(joinpath(tablas_path, "6_analisis_compensacion_$(extra_descriptor_AC)_$(contingencia).csv"), analisis_compensacion)

    if "statcom" in include_in_grid
        df_statcom = DataFrame(
            Hora            = 0:23,
            V_Barra         = resultados_voltaje[!, "Barra_$(bus_statcom_number)"],
            Q_STATCOM_MVAr  = q_statcom_mvar,
            Saturado        = abs.(q_statcom_mvar) .>= (Q_statcom_mvar * 0.999)
        )
        CSV.write(joinpath(tablas_path, "9_STATCOM_$(extra_descriptor_AC)_$(contingencia).csv"), df_statcom)
    end

    return nothing
end

# ==========================================================
# Ejecutar: una corrida por cada combinación (barra STATCOM × contingencia)
# ==========================================================
for contingencia in tipos_contingencia
    if "statcom" in include_in_grid
        for bus_num in barras
            correr_flujo_potencia(sys, contingencia; bus_statcom_number=bus_num)
        end
    else
        correr_flujo_potencia(sys, contingencia)
    end
end

println("\nTodas las combinaciones fueron simuladas.")

### PARA LAS CONTINGENCIAS HACER OTRO DEEPCOPY PARA NO ALTERAR SISTEMA ORIGINAL