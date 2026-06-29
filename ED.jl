using PowerSystems, PowerSimulations, PowerFlows
using Dates, TimeSeries
using Ipopt
using CSV, DataFrames, Plots

# 0. Carpeta para guardar el modelo de Despacho Económico (ED)
ed_model_output = joinpath(@__DIR__, "ED_model")
if !isdir(ed_model_output)
    mkdir(ed_model_output)
end

# 1. Carga del sistema
file_path_static = joinpath(@__DIR__, "IEEE_14_Bus_Proyecto.m")
if !isfile(file_path_static)
    error("No se encontró el archivo .m en el directorio.")
end

println("Cargando sistema estático desde '$(basename(file_path_static))'...")
sys = System(file_path_static)
S_base = get_base_power(sys)

# ########################  NO MODIFICAR ESTA PONDERACIÓN ########################
# Ponderamos la demanda para aumentarla en un 10% según el enunciado
λ_load = 1.10
cargas = collect(get_components(PowerLoad, sys));

for load in cargas
    set_active_power!(load, get_active_power(load) * λ_load)
    set_reactive_power!(load, get_reactive_power(load) * λ_load)
end
# ########################  NO MODIFICAR ESTA PONDERACIÓN ########################

# 2. Reemplazo de un generador síncrono por una planta renovable solar de igual capacidad con RenewableDispatch 
gen_termico_a_retirar = get_component(ThermalStandard, sys, "gen-3")
max_active_power_gen_a_retirar = get_max_active_power(gen_termico_a_retirar)
bus_solar = get_bus(gen_termico_a_retirar)

remove_component!(sys, gen_termico_a_retirar)

# Capacidad del panel solar
cap_max_gen_solar = round(max_active_power_gen_a_retirar, digits=2)
# Segun enunciado, como no tenemos capacidad de regular Q, entonces este se convierte de PV a PQ.
set_bustype!(bus_solar, PowerSystems.ACBusTypes.PQ)
# Configuramos RenewableDispatch para modelar la planta solar
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

# La añadimos al sistema
add_component!(sys, gen_solar)

# 3. Definición de funciones de costo para el resto de generadores térmicos
# Genéricamente: C(P) = a + (b)P + (c)P^2

# Como para el panel fotovoltaico ya definimos la función de costo (costo nulo) solo asignamos a los generadores térmicos
gens_termicos = sort!(collect(get_components(ThermalStandard, sys)), by=x -> get_name(x))

# SE CAMBIARON SEGUN ENUNCIADO
costos_fijos = [2100.0, 7200.0, 6250.0, 2000.0] # a
costos_variables = [(0.1, 10.0), (0.06, 7.0), (0.07, 8.0), (0.5, 60.0)] # (c,b)

# Se le asigna a cada generador térmico la función de costos cuadrática 
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

# 4. Formulación del ED con TimeSeries
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

# 5. Plantilla de ED
template_ed = template_economic_dispatch()
set_network_model!(template_ed, NetworkModel(CopperPlatePowerModel, duals=[CopperPlateBalanceConstraint]))

# Optimizador y DecisionModel
optimizer = optimizer_with_attributes(Ipopt.Optimizer, "print_level" => 3) # "print_level" es solo la verbosidad
# en el output del solver
modelo_ed = DecisionModel(template_ed, sys, optimizer=optimizer, horizon=24)

# 6. Construir el modelo y resolver el ED
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
# 1. Los puntos de despacho de potencia activa (MW) de todas las unidades generadoras
# en cada hora, otorgados por los EDs.
# Aprovecho de agregar una nueva columna con la suma de generacion por cada fila.
despacho_p_print.Demanda_Total_MW = sum.(eachrow(despacho_p_print[!, 2:end]))
#CSV.write(joinpath(tablas_path, "1_despachos_generacion.csv"), despacho_p_print)

# 2. El costo total minimizado al final del d´ıa de ma˜nana, otorgado por los EDs.
# Resultados para función objetivo - costos minimizados:
#  VALOR OBTENIDO EN CONSOLA:  31147.352583930755

# 3. La evolucion de la demanda total (MW) del sistema en cada hora del dia, esclareciendo
# si es o no satisfecha con los despachos calculados en 1. Identifique el o los horarios de
# mayor demanda.

demanda_base_total_mw = sum(get_active_power(load) for load in get_components(PowerLoad, sys)) * S_base
demanda_real_mw = demanda_base_total_mw .* df_perfiles.Demanda_normalizada
df_demanda = DataFrame(
    DateTime = timestamps,
    Demanda_Total_MW = demanda_real_mw
)
#CSV.write(joinpath(tablas_path, "2_demanda_total_real.csv"), df_demanda)

# Como en el inciso 1. ya agregamos la suma, basta con comparar la suma de generacion por hora
# con la demanda_total_real anterior.

# 4. La evoluci´on del costo marginal λ de la energ´ıa (en USD/MWh) del sistema en cada
#   hora del d´ıa, otorgado por los EDs.
#CSV.write(joinpath(tablas_path, "4_costo_marginal.csv"), lambda_mw)



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
        println("OJITO PIOJO: El flujo de potencia no convergió en la Hora $i")
    end
end
println("\nFlujos de potencia Exitosos")
display(resultados_voltaje)

#CSV.write(joinpath(tablas_path, "5_perfiles_voltaje.csv"), resultados_voltaje)

### PARA LAS CONTINGENCIAS HACER OTRO DEEPCOPY PARA NO ALTERAR SISTEMA ORIGINAL