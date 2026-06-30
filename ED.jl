using PowerSystems, PowerSimulations, PowerFlows
using Dates, TimeSeries
using Ipopt
using CSV, DataFrames, Plots

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
tipo_contingencia = "normal" # line para caida de linea 2-3; gen para caída de gen síncrono en barra 2; normal para modo normal

#Ponderación 10% 
λ_load = 1.10
cargas = collect(get_components(PowerLoad, sys));
for load in cargas
    set_active_power!(load, get_active_power(load) * λ_load)
    set_reactive_power!(load, get_reactive_power(load) * λ_load)
    set_max_active_power!(load, get_max_active_power(load) * λ_load)
    set_max_reactive_power!(load, get_max_reactive_power(load) * λ_load)
end

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

# Optimizador y DecisionModel
optimizer = optimizer_with_attributes(Ipopt.Optimizer, "print_level" => 3) # "print_level" es solo la verbosidad
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
despacho_p_print = select(despacho_p, ["DateTime"; sort(names(despacho_p)[2:end])])
display(despacho_p_print)
println("\nResultados para función objetivo - costos minimizados:")
stats = read_optimizer_stats(res)
println(stats[1, :objective_value])
println("\nResultados para variables duales - precio de la energía (\$/MWh):")
duals = read_duals(res)
# La restricción de balance de potencia está formulada en pu, su dual está en $/pu.
lambda_pu = duals["CopperPlateBalanceConstraint__System"]
# Dividimos por S_base para obtener el costo marginal en $/MWh.
lambda_mw = DataFrame(DateTime=lambda_pu.DateTime, Lambda_MW=lambda_pu[!, 2] ./ S_base)
display(lambda_mw)

# Las salidas de este código deberán ser consideradas como los setpoints de potencia activa a emplear en 
# la resolución de los flujos de potencia. 

### GUARDAR INFO PARA ANALISIS ###
tablas_path = "Tablas_Resultados_ED"
mkpath(tablas_path)

# Limpieza de valores pequeños negativos antes de exportar
for col in names(despacho_p_print)[2:end]
    despacho_p_print[!, col] = [x < 1e-5 ? 0.0 : x for x in despacho_p_print[!, col]]
end

despacho_p_print.Demanda_Total_MW = sum.(eachrow(despacho_p_print[!, 2:end]))

# Los puntos de despacho de potencia activa (MW) de todas las unidades generadoras en cada hora, otorgados por los EDs.
# Aprovecho de agregar una nueva columna con la suma de generacion por cada fila.
CSV.write(joinpath(tablas_path, "1_despachos_generacion.csv"), despacho_p_print)

# El costo total minimizado al final del d´ıa de ma˜nana, otorgado por los EDs.
# Resultados para función objetivo - costos minimizados:
#  VALOR OBTENIDO EN CONSOLA:  31147.352583930755

# La evolucion de la demanda total (MW) del sistema en cada hora del dia, esclareciendo
# si es o no satisfecha con los despachos calculados en 1. Identifique el o los horarios de
# mayor demanda.

demanda_base_total_mw = sum(get_active_power(load) for load in get_components(PowerLoad, sys)) * S_base
demanda_real_mw = demanda_base_total_mw .* df_perfiles.Demanda_normalizada
df_demanda = DataFrame(
    DateTime = timestamps,
    Demanda_Total_MW = demanda_real_mw
)
CSV.write(joinpath(tablas_path, "2_demanda_total_real.csv"), df_demanda)

# Comparación explícita: generación total despachada vs demanda real por hora
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
CSV.write(joinpath(tablas_path, "3_comparacion_gen_dem.csv"), df_comparacion)

# La evoluci´on del costo marginal λ de la energ´ıa (en USD/MWh) del sistema en cada hora del d´ıa, otorgado por los EDs.
CSV.write(joinpath(tablas_path, "4_costo_marginal.csv"), lambda_mw)



### PARTE DE FLUJO DE POTENCIA PA HACER LA 5.

println("FLujo potencia iniciado")

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

# en el loop de aca abajo se corre para cada hora un flujo. Para eso, primero
# se actualizan los valores de las demandas para esa hora según el .csv entregado
for i in 1:24
    if i == 21
        println("\n\nSon las 21:00\n")
        if tipo_contingencia=="line"
            line_2_3 = get_component(ACBranch, sys_flujo, "2-3-i_3")
            remove_component!(sys_flujo, line_2_3)
            println("Contingencia aplicada: salida linea 2-3\n\n")
        elseif tipo_contingencia == "gen"
            gen_barra2 = get_component(ThermalStandard, sys, "gen-2")
            remove_component!(sys_flujo, gen_barra2)
            gens_termicos_flujo = sort!(collect(get_components(ThermalStandard, sys_flujo)), by=x -> get_name(x))
            println("Contingencia aplicada: caida generador barra 2\n\n")
        elseif tipo_contingencia == "normal"
            println("Modo de operación normal\n\n")
        else
            tipo_contingencia = "normal"
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

    for g in gens_termicos_flujo
        nombre_gen = get_name(g)
        p_despacho_mw = despacho_p_print[i, nombre_gen]
        set_active_power!(g, p_despacho_mw / S_base)
    end
    
    res_temp = PowerFlows.solve_powerflow(ac_pf_solver, sys_flujo)
    if isa(res_temp, Dict)
        df_temp = res_temp["bus_results"]
        
        for b in barras
            num_bar = get_number(b)
            # Buscamos el voltaje de esta barra en el DataFrame de resultados
            v_actual = df_temp[df_temp.bus_number .== num_bar, :Vm][1]
            resultados_voltaje[i, "Barra_$num_bar"] = v_actual
        end
    else
        println("OJITO PIOJO: El flujo de potencia no convergió en la Hora $i") # XDDDDDDDDD
    end
end
println("\nFlujos de potencia Exitosos")
display(resultados_voltaje)

CSV.write(joinpath(tablas_path, "5_perfiles_voltaje_modo_$(tipo_contingencia).csv"), resultados_voltaje)

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
CSV.write(joinpath(tablas_path, "5b_violaciones_voltaje_modo_$(tipo_contingencia).csv"), violaciones)

### PARA LAS CONTINGENCIAS HACER OTRO DEEPCOPY PARA NO ALTERAR SISTEMA ORIGINAL
