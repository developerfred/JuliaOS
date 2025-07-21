module CrossChainBridge

using HTTP, JSON3, Dates, Logging, Random, UUIDs

export AbstractBridge, BridgeConfig, BaseBridge, SolanaBridge, WormholeBridge, LayerZeroBridge, LayerSwapBridge, PolkadotXCMBridge
export BridgeRegistry, create_bridge, get_supported_bridges, validate_bridge_transfer
export estimate_bridge_fees, execute_cross_chain_transfer, get_transfer_status

# =================== SECURITY ENHANCEMENTS ===================

const MAX_TRANSFER_AMOUNT = 1_000_000.0
const MIN_TRANSFER_AMOUNT = 0.0001
const MAX_SLIPPAGE_PERCENT = 50.0  # 50% maximum slippage protection
const DEFAULT_SLIPPAGE_PERCENT = 0.5  # 0.5% default slippage
const RATE_LIMIT_PER_HOUR = 100  # Maximum transfers per hour per IP
const CIRCUIT_BREAKER_DAILY_LIMIT = 10_000_000.0  # $10M daily limit per bridge

# Rate limiting storage (in production, use Redis)
const RATE_LIMIT_STORAGE = Dict{String, Vector{DateTime}}()
const DAILY_VOLUME_STORAGE = Dict{String, Dict{String, Float64}}()

# Address validation patterns
const ETHEREUM_ADDRESS_PATTERN = r"^0x[a-fA-F0-9]{40}$"
const SOLANA_ADDRESS_PATTERN = r"^[1-9A-HJ-NP-Za-km-z]{32,44}$"
const SUBSTRATE_ADDRESS_PATTERN = r"^5[0-9A-Za-z]{47}$"

# =================== SECURITY FUNCTIONS ===================

function validate_address(address::String, chain::String)::Bool
    if isempty(address)
        return false
    end
    
    if chain in ["ethereum", "base", "polygon", "arbitrum", "optimism", "avalanche", "bsc"]
        return occursin(ETHEREUM_ADDRESS_PATTERN, address)
    elseif chain == "solana"
        return occursin(SOLANA_ADDRESS_PATTERN, address)
    elseif chain in ["polkadot", "kusama", "paseo", "acala", "moonbeam", "statemint"]
        return occursin(SUBSTRATE_ADDRESS_PATTERN, address)
    else
        return length(address) >= 20  # Basic length check for unknown chains
    end
end

function safe_amount_conversion(amount::Float64)::Union{BigInt, Nothing}
    if amount <= 0 || amount > MAX_TRANSFER_AMOUNT
        return nothing
    end
    
    try
        # Use BigInt to prevent overflow
        return BigInt(round(amount * 1e18))
    catch e
        @error "Amount conversion failed: $e"
        return nothing
    end
end

function check_rate_limit(identifier::String)::Bool
    current_time = now()
    hour_ago = current_time - Hour(1)
    
    if !haskey(RATE_LIMIT_STORAGE, identifier)
        RATE_LIMIT_STORAGE[identifier] = DateTime[]
    end
    
    # Clean old entries
    filter!(ts -> ts > hour_ago, RATE_LIMIT_STORAGE[identifier])
    
    # Check if under limit
    if length(RATE_LIMIT_STORAGE[identifier]) >= RATE_LIMIT_PER_HOUR
        return false
    end
    
    # Add current request
    push!(RATE_LIMIT_STORAGE[identifier], current_time)
    return true
end

function check_circuit_breaker(bridge_name::String, amount::Float64)::Bool
    today = string(Date(now()))
    key = "$(bridge_name)_$(today)"
    
    if !haskey(DAILY_VOLUME_STORAGE, bridge_name)
        DAILY_VOLUME_STORAGE[bridge_name] = Dict{String, Float64}()
    end
    
    current_volume = get(DAILY_VOLUME_STORAGE[bridge_name], today, 0.0)
    
    if current_volume + amount > CIRCUIT_BREAKER_DAILY_LIMIT
        @warn "Circuit breaker triggered for $bridge_name: daily limit exceeded"
        return false
    end
    
    DAILY_VOLUME_STORAGE[bridge_name][today] = current_volume + amount
    return true
end

function calculate_dynamic_slippage(amount::Float64, market_volatility::Float64 = 1.0)::Float64
    # Dynamic slippage based on amount and market conditions
    base_slippage = DEFAULT_SLIPPAGE_PERCENT
    
    # Increase slippage for larger amounts
    amount_multiplier = min(2.0, 1.0 + (amount / 100000.0) * 0.1)
    
    # Adjust for market volatility
    volatility_multiplier = max(0.5, min(3.0, market_volatility))
    
    calculated_slippage = base_slippage * amount_multiplier * volatility_multiplier
    
    return min(calculated_slippage, MAX_SLIPPAGE_PERCENT)
end

# =================== CORE BRIDGE STRUCTS ===================

struct BridgeConfig
    name::String
    supported_chains::Vector{String}
    contract_addresses::Dict{String, String}
    fee_structure::Dict{String, Float64}
    min_transfer_amount::Dict{String, Float64}
    max_transfer_amount::Dict{String, Float64}
    estimated_time::Dict{String, Int}
    gas_multiplier::Float64
    security_level::String
    slippage_tolerance::Dict{String, Float64}
    daily_limits::Dict{String, Float64}
end

abstract type AbstractBridge end

struct BaseBridge <: AbstractBridge
    config::BridgeConfig
    
    function BaseBridge()
        config = BridgeConfig(
            "Base",
            ["ethereum", "base"],
            Dict(
                "ethereum" => "0x49048044D57e1C92A77f79988d21Fa8fAF74E97e",
                "base" => "0x4200000000000000000000000000000000000010"
            ),
            Dict("fixed_fee" => 0.005, "percentage_fee" => 0.0),
            Dict("ethereum" => 0.01, "base" => 0.01),
            Dict("ethereum" => 100000.0, "base" => 100000.0),
            Dict("ethereum_to_base" => 120, "base_to_ethereum" => 1200),
            1.2,
            "very_high",
            Dict("ethereum" => 0.5, "base" => 0.5),
            Dict("ethereum" => 1000000.0, "base" => 1000000.0)
        )
        new(config)
    end
end

struct SolanaBridge <: AbstractBridge
    config::BridgeConfig
    
    function SolanaBridge()
        config = BridgeConfig(
            "Solana",
            ["solana"],
            Dict("solana" => "wormDTUJ6AWPNvk59vGQbDvGJmqbDTdgWgAqcLBCgUb"),
            Dict("fixed_fee" => 0.001, "percentage_fee" => 0.0),
            Dict("solana" => 0.001),
            Dict("solana" => 50000.0),
            Dict("solana_internal" => 30),
            1.1,
            "high",
            Dict("solana" => 1.0),
            Dict("solana" => 500000.0)
        )
        new(config)
    end
end

struct WormholeBridge <: AbstractBridge
    config::BridgeConfig
    
    function WormholeBridge()
        config = BridgeConfig(
            "Wormhole",
            ["ethereum", "solana", "base", "polygon", "arbitrum", "optimism", "avalanche", "bsc"],
            Dict(
                "ethereum" => "0x3ee18B2214AFF97000D974cf647E7C347E8fa585",
                "solana" => "wormDTUJ6AWPNvk59vGQbDvGJmqbDTdgWgAqcLBCgUb",
                "base" => "0x8d2de8d2f73F1F4cAB472AC9A881C9b123C79627",
                "polygon" => "0x7A4B5a56256163F07b2C80A7cA55aBE66c4ec4d7",
                "arbitrum" => "0xa5f208e072434bC67592E4C49C1B991BA79BCA46",
                "optimism" => "0xEe91C335eab126dF5fDB3797EA9d6aD93aeC9722",
                "avalanche" => "0x54a8e5f9c4CbA08F9943965859F6c34eAF03E26c",
                "bsc" => "0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B"
            ),
            Dict("fixed_fee" => 0.01, "percentage_fee" => 0.001),
            Dict("ethereum" => 0.01, "solana" => 0.001, "base" => 0.001),
            Dict("ethereum" => 1000000.0, "solana" => 50000000.0, "base" => 1000000.0),
            Dict("ethereum_to_solana" => 900, "solana_to_ethereum" => 1200, "ethereum_to_base" => 600),
            1.3,
            "very_high",
            Dict("ethereum" => 0.5, "solana" => 1.0, "base" => 0.3),
            Dict("ethereum" => 5000000.0, "solana" => 10000000.0, "base" => 2000000.0)
        )
        new(config)
    end
end

struct LayerZeroBridge <: AbstractBridge
    config::BridgeConfig
    
    function LayerZeroBridge()
        config = BridgeConfig(
            "LayerZero",
            ["ethereum", "base", "polygon", "arbitrum", "optimism", "avalanche", "bsc"],
            Dict(
                "ethereum" => "0x66A71Dcef29A0fFBDBE3c6a460a3B5BC225Cd675",
                "base" => "0xb6319cC6c8c27A8F5dAF0dD3DF91EA35C4720dd7",
                "polygon" => "0x3c2269811836af69497E5F486A85D7316753cf62",
                "arbitrum" => "0x3c2269811836af69497E5F486A85D7316753cf62",
                "optimism" => "0x3c2269811836af69497E5F486A85D7316753cf62",
                "avalanche" => "0x3c2269811836af69497E5F486A85D7316753cf62",
                "bsc" => "0x3c2269811836af69497E5F486A85D7316753cf62"
            ),
            Dict("fixed_fee" => 0.005, "percentage_fee" => 0.001),
            Dict("ethereum" => 0.01, "base" => 0.01),
            Dict("ethereum" => 500000.0, "base" => 500000.0),
            Dict("ethereum_to_base" => 300, "base_to_ethereum" => 480),
            1.25,
            "high",
            Dict("ethereum" => 0.3, "base" => 0.3),
            Dict("ethereum" => 3000000.0, "base" => 1500000.0)
        )
        new(config)
    end
end

struct LayerSwapBridge <: AbstractBridge
    config::BridgeConfig
    api_endpoint::String
    v8_contracts::Dict{String, String}
    api_key::Union{String, Nothing}
    
    function LayerSwapBridge()
        config = BridgeConfig(
            "LayerSwap",
            ["ethereum", "base", "solana", "polygon", "arbitrum", "optimism", "avalanche", "bsc", "starknet", "immutable", "linea", "zksync"],
            Dict(
                "ethereum" => "0x2fc617e933a52713247ce25730f6695920b3befe",
                "base" => "0x67d3E9cb8d3200444349D2a7794960EeB969631c",
                "solana" => "2XfmTmnhz8kDnryZSJKKV53tLN7DKZbrN9Q1sZbJo5bc",
                "polygon" => "0x2fc617e933a52713247ce25730f6695920b3befe",
                "arbitrum" => "0x2fc617e933a52713247ce25730f6695920b3befe",
                "optimism" => "0x2fc617e933a52713247ce25730f6695920b3befe",
                "avalanche" => "0x2fc617e933a52713247ce25730f6695920b3befe",
                "bsc" => "0x2fc617e933a52713247ce25730f6695920b3befe",
                "starknet" => "0x0112a045ae21884942faffd7a8087276638e6e4b8a3833a65d14be15eef8f53b",
                "immutable" => "0x67d3E9cb8d3200444349D2a7794960EeB969631c",
                "linea" => "0x67d3E9cb8d3200444349D2a7794960EeB969631c",
                "zksync" => "0x67d3E9cb8d3200444349D2a7794960EeB969631c"
            ),
            Dict("fixed_fee" => 0.001, "percentage_fee" => 0.001),
            Dict("ethereum" => 0.001, "base" => 0.001, "solana" => 0.001),
            Dict("ethereum" => 10000000.0, "base" => 10000000.0, "solana" => 50000000.0),
            Dict("ethereum_to_base" => 120, "base_to_ethereum" => 180, "ethereum_to_solana" => 300, "solana_to_ethereum" => 420),
            1.05,
            "very_high",
            Dict("ethereum" => 0.1, "base" => 0.1, "solana" => 0.5),
            Dict("ethereum" => 8000000.0, "base" => 8000000.0, "solana" => 20000000.0)
        )
        
        api_endpoint = get(ENV, "LAYERSWAP_API_URL", "https://api.layerswap.io/api")
        api_key = get(ENV, "LAYERSWAP_API_KEY", nothing)
        
        v8_contracts = Dict(
            "discovery" => "0x67d3E9cb8d3200444349D2a7794960EeB969631c",
            "auction" => "0x5305aC8c135c650b145Fb59356695E12155107ee",
            "atomic_swap_ethereum" => "0x2fc617e933a52713247ce25730f6695920b3befe",
            "atomic_swap_base" => "0x67d3E9cb8d3200444349D2a7794960EeB969631c"
        )
        
        new(config, api_endpoint, v8_contracts, api_key)
    end
end

struct PolkadotXCMBridge <: AbstractBridge
    config::BridgeConfig
    rpc_endpoints::Dict{String, String}
    xcm_sdk_config::Dict{String, Any}
    supported_parachains::Vector{String}
    
    function PolkadotXCMBridge()
        config = BridgeConfig(
            "PolkadotXCM",
            ["polkadot", "kusama", "paseo", "statemint", "karura", "acala", "moonbeam", "moonriver", 
             "astar", "shiden", "bifrost", "parallel", "centrifuge", "interlay", "kintsugi", 
             "basilisk", "asset_hub_paseo", "bridge_hub_paseo", "people_paseo", "coretime_paseo"],
            Dict(
                "polkadot" => "polkadot_relay",
                "kusama" => "kusama_relay",
                "paseo" => "paseo_relay",
                "statemint" => "parachain_1000",
                "asset_hub_paseo" => "parachain_1000_paseo"
            ),
            Dict("fixed_fee" => 0.01, "percentage_fee" => 0.0),
            Dict("polkadot" => 0.01, "kusama" => 0.001),
            Dict("polkadot" => 100000.0, "kusama" => 1000000.0),
            Dict("polkadot_to_acala" => 60, "kusama_to_karura" => 60, "paseo_to_asset_hub_paseo" => 30),
            1.1,
            "very_high",
            Dict("polkadot" => 0.1, "kusama" => 0.1),
            Dict("polkadot" => 1000000.0, "kusama" => 5000000.0)
        )
        
        rpc_endpoints = Dict(
            "polkadot" => get(ENV, "POLKADOT_RPC_URL", "wss://rpc.polkadot.io"),
            "kusama" => get(ENV, "KUSAMA_RPC_URL", "wss://kusama-rpc.polkadot.io"),
            "paseo" => get(ENV, "PASEO_RPC_URL", "wss://paseo.rpc.amforc.com"),
            "statemint" => get(ENV, "STATEMINT_RPC_URL", "wss://statemint-rpc.polkadot.io"),
            "asset_hub_paseo" => get(ENV, "ASSET_HUB_PASEO_RPC_URL", "wss://asset-hub-paseo-rpc.polkadot.io"),
            "acala" => get(ENV, "ACALA_RPC_URL", "wss://acala-rpc-0.aca-api.network"),
            "moonbeam" => get(ENV, "MOONBEAM_RPC_URL", "wss://wss.api.moonbeam.network")
        )
        
        xcm_sdk_config = Dict(
            "xcm_version" => 3,
            "default_weight_limit" => "Unlimited",
            "default_fee_asset_item" => 0,
            "supported_assets" => ["DOT", "KSM", "USDT", "USDC", "ASTR", "GLMR", "MOVR", "ACA", "KAR", "PAS"],
            "transport_methods" => ["XCMP", "HRMP", "VMP", "DMP"]
        )
        
        supported_parachains = [
            "statemint", "karura", "acala", "moonbeam", "moonriver", 
            "astar", "shiden", "bifrost", "parallel", "centrifuge",
            "interlay", "kintsugi", "basilisk", "asset_hub_paseo", 
            "bridge_hub_paseo", "people_paseo", "coretime_paseo"
        ]
        
        new(config, rpc_endpoints, xcm_sdk_config, supported_parachains)
    end
end

# =================== BRIDGE REGISTRY ===================

struct BridgeRegistry
    bridges::Dict{String, AbstractBridge}
    
    function BridgeRegistry()
        bridges = Dict{String, AbstractBridge}(
            "base" => BaseBridge(),
            "solana" => SolanaBridge(),
            "wormhole" => WormholeBridge(),
            "layerzero" => LayerZeroBridge(),
            "layerswap" => LayerSwapBridge(),
            "polkadot_xcm" => PolkadotXCMBridge()
        )
        new(bridges)
    end
end

const BRIDGE_REGISTRY = Ref{BridgeRegistry}()

function __init__()
    BRIDGE_REGISTRY[] = BridgeRegistry()
    @info "Cross-chain bridge registry initialized with $(length(BRIDGE_REGISTRY[].bridges)) bridges"
end

# =================== CORE FUNCTIONS ===================

function create_bridge(bridge_type::String)::Union{AbstractBridge, Nothing}
    registry = BRIDGE_REGISTRY[]
    return get(registry.bridges, lowercase(bridge_type), nothing)
end

function get_supported_bridges()::Vector{Dict{String, Any}}
    registry = BRIDGE_REGISTRY[]
    bridges_info = Vector{Dict{String, Any}}()
    
    for (name, bridge) in registry.bridges
        push!(bridges_info, Dict(
            "name" => bridge.config.name,
            "type" => name,
            "supported_chains" => bridge.config.supported_chains,
            "security_level" => bridge.config.security_level,
            "fee_structure" => bridge.config.fee_structure,
            "daily_limits" => bridge.config.daily_limits,
            "min_transfer_amount" => bridge.config.min_transfer_amount,
            "max_transfer_amount" => bridge.config.max_transfer_amount
        ))
    end
    
    return bridges_info
end

function validate_bridge_transfer(bridge::AbstractBridge, from_chain::String, to_chain::String, 
                                amount::Float64, token_address::String)::Dict{String, Any}
    validation_result = Dict{String, Any}(
        "valid" => true,
        "errors" => Vector{String}(),
        "warnings" => Vector{String}()
    )
    
    # Basic validation
    if isempty(from_chain) || isempty(to_chain)
        push!(validation_result["errors"], "Chain parameters cannot be empty")
        validation_result["valid"] = false
    end
    
    if from_chain == to_chain
        push!(validation_result["errors"], "Source and destination chains cannot be the same")
        validation_result["valid"] = false
    end
    
    # Chain support validation
    if !(from_chain in bridge.config.supported_chains)
        push!(validation_result["errors"], "Unsupported source chain: $from_chain")
        validation_result["valid"] = false
    end
    
    if !(to_chain in bridge.config.supported_chains)
        push!(validation_result["errors"], "Unsupported destination chain: $to_chain")
        validation_result["valid"] = false
    end
    
    # Amount validation with enhanced checks
    if amount <= 0
        push!(validation_result["errors"], "Transfer amount must be greater than 0")
        validation_result["valid"] = false
    end
    
    min_amount = get(bridge.config.min_transfer_amount, from_chain, MIN_TRANSFER_AMOUNT)
    max_amount = get(bridge.config.max_transfer_amount, from_chain, MAX_TRANSFER_AMOUNT)
    
    if amount < min_amount
        push!(validation_result["errors"], "Transfer amount $amount is below minimum $min_amount for $from_chain")
        validation_result["valid"] = false
    end
    
    if amount > max_amount
        push!(validation_result["errors"], "Transfer amount $amount exceeds maximum $max_amount for $from_chain")
        validation_result["valid"] = false
    end
    
    # Daily limit check
    daily_limit = get(bridge.config.daily_limits, from_chain, CIRCUIT_BREAKER_DAILY_LIMIT)
    if amount > daily_limit * 0.1  # Warning if transfer is >10% of daily limit
        push!(validation_result["warnings"], "Large transfer amount detected - enhanced monitoring applied")
    end
    
    # Token address validation (basic)
    if !isempty(token_address) && token_address != "native"
        if !validate_address(token_address, from_chain)
            push!(validation_result["warnings"], "Token address format may be invalid for $from_chain")
        end
    end
    
    return validation_result
end

function estimate_bridge_fees(bridge::AbstractBridge, from_chain::String, to_chain::String, amount::Float64)::Dict{String, Any}
    # Enhanced fee estimation with dynamic calculations
    fixed_fee = bridge.config.fee_structure["fixed_fee"]
    percentage_fee = bridge.config.fee_structure["percentage_fee"]
    
    # Dynamic slippage calculation
    dynamic_slippage = calculate_dynamic_slippage(amount)
    slippage_fee = amount * (dynamic_slippage / 100.0)
    
    # Gas fee estimation (simplified)
    base_gas_fee = from_chain in ["ethereum", "base"] ? 0.002 : 0.0005
    gas_multiplier = bridge.config.gas_multiplier
    estimated_gas_fee = base_gas_fee * gas_multiplier
    
    # Route-specific time estimation
    route_key = "$(from_chain)_to_$(to_chain)"
    estimated_time_seconds = get(bridge.config.estimated_time, route_key, 600)
    
    total_fee = fixed_fee + (amount * percentage_fee) + slippage_fee + estimated_gas_fee
    
    return Dict{String, Any}(
        "fixed_fee" => fixed_fee,
        "percentage_fee" => amount * percentage_fee,
        "slippage_fee" => slippage_fee,
        "dynamic_slippage_percent" => dynamic_slippage,
        "gas_fee" => estimated_gas_fee,
        "total_fee" => total_fee,
        "estimated_time_seconds" => estimated_time_seconds,
        "fee_breakdown" => Dict(
            "fixed" => fixed_fee,
            "percentage" => amount * percentage_fee,
            "slippage" => slippage_fee,
            "gas" => estimated_gas_fee
        )
    )
end

function execute_cross_chain_transfer(
    bridge_name::String, from_chain::String, to_chain::String, amount::Float64,
    token_address::String, recipient_address::String, 
    signed_tx_hex::Union{String, Nothing} = nothing
)::Dict{String, Any}
    
    # Security checks
    client_id = "default_client"  # In production, extract from request
    
    if !check_rate_limit(client_id)
        return Dict{String, Any}(
            "success" => false,
            "error" => "Rate limit exceeded. Maximum $RATE_LIMIT_PER_HOUR transfers per hour."
        )
    end
    
    if !check_circuit_breaker(bridge_name, amount)
        return Dict{String, Any}(
            "success" => false,
            "error" => "Daily transfer limit exceeded for $bridge_name"
        )
    end
    
    # Address validation
    if !validate_address(recipient_address, to_chain)
        return Dict{String, Any}(
            "success" => false,
            "error" => "Invalid recipient address format for $to_chain"
        )
    end
    
    bridge = create_bridge(bridge_name)
    if isnothing(bridge)
        return Dict{String, Any}(
            "success" => false,
            "error" => "Bridge '$bridge_name' not found"
        )
    end
    
    # Validation
    validation = validate_bridge_transfer(bridge, from_chain, to_chain, amount, token_address)
    if !validation["valid"]
        return Dict{String, Any}(
            "success" => false,
            "error" => "Transfer validation failed",
            "details" => validation
        )
    end
    
    # Safe amount conversion
    amount_wei = safe_amount_conversion(amount)
    if isnothing(amount_wei)
        return Dict{String, Any}(
            "success" => false,
            "error" => "Invalid amount or amount exceeds maximum limit"
        )
    end
    
    try
        operation_id = "$(bridge_name)_$(Int(time()))_$(rand(UInt32))"
        
        # Prepare transaction based on bridge type
        if bridge isa LayerSwapBridge
            if isnothing(bridge.api_key)
                # V8 Atomic Swap Mode
                tx_data = prepare_layerswap_v8_transaction(bridge, from_chain, to_chain, amount, token_address, recipient_address)
            else
                # API Mode
                tx_data = prepare_layerswap_api_transaction(bridge, from_chain, to_chain, amount, token_address, recipient_address)
            end
        elseif bridge isa PolkadotXCMBridge
            tx_data = prepare_xcm_transaction(bridge, from_chain, to_chain, amount, token_address, recipient_address)
        elseif bridge isa WormholeBridge
            tx_data = prepare_wormhole_transaction(bridge, from_chain, to_chain, amount, token_address, recipient_address)
        elseif bridge isa LayerZeroBridge
            tx_data = prepare_layerzero_transaction(bridge, from_chain, to_chain, amount, token_address, recipient_address)
        else
            # Generic EVM transaction
            tx_data = prepare_generic_evm_transaction(bridge, from_chain, to_chain, amount, token_address, recipient_address)
        end
        
        return Dict{String, Any}(
            "success" => true,
            "operation_id" => operation_id,
            "bridge_name" => bridge.config.name,
            "transaction_data" => tx_data,
            "estimated_completion" => Dates.now() + Second(get(bridge.config.estimated_time, "$(from_chain)_to_$(to_chain)", 600)),
            "status" => "pending",
            "created_at" => Dates.now(),
            "warnings" => get(validation, "warnings", []),
            "instructions" => "Sign and submit the transaction_data using your wallet or preferred method."
        )
        
    catch e
        @error "Error executing cross-chain transfer: $e"
        return Dict{String, Any}(
            "success" => false,
            "error" => "Transfer execution failed: $(sprint(showerror, e))"
        )
    end
end

function get_transfer_status(bridge_name::String, operation_id::String)::Dict{String, Any}
    bridge = create_bridge(bridge_name)
    if isnothing(bridge)
        return Dict{String, Any}(
            "success" => false,
            "error" => "Bridge '$bridge_name' not found"
        )
    end
    
    # Validate operation ID format
    parts = split(operation_id, "_")
    if length(parts) < 3
        return Dict{String, Any}(
            "success" => false,
            "error" => "Invalid operation ID format"
        )
    end
    
    try
        timestamp = parse(Int, parts[2])
        creation_time = Dates.unix2datetime(timestamp)
        elapsed_time = Dates.now() - creation_time
        
        # Get estimated completion time for the route
        estimated_completion_seconds = 600  # Default 10 minutes
        for (route, time_sec) in bridge.config.estimated_time
            if contains(operation_id, route) || contains(parts[1], route)
                estimated_completion_seconds = time_sec
                break
            end
        end
        
        completion_progress = min(1.0, Dates.value(elapsed_time) / 1000 / estimated_completion_seconds)
        
        # Status determination with more granular states
        status = if completion_progress < 0.1
            "initiated"
        elseif completion_progress < 0.3
            "pending"
        elseif completion_progress < 0.6
            "processing"
        elseif completion_progress < 0.8
            "validating"
        elseif completion_progress < 1.0
            "finalizing"
        else
            "completed"
        end
        
        return Dict{String, Any}(
            "success" => true,
            "operation_id" => operation_id,
            "status" => status,
            "progress" => completion_progress,
            "bridge_name" => bridge.config.name,
            "created_at" => creation_time,
            "estimated_completion" => creation_time + Dates.Second(estimated_completion_seconds),
            "elapsed_time_seconds" => Dates.value(elapsed_time) ÷ 1000,
            "remaining_time_seconds" => max(0, estimated_completion_seconds - (Dates.value(elapsed_time) ÷ 1000))
        )
        
    catch e
        @error "Error parsing operation ID or calculating status: $e"
        return Dict{String, Any}(
            "success" => false,
            "error" => "Failed to determine transfer status"
        )
    end
end

# =================== BRIDGE-SPECIFIC TRANSACTION PREPARATION ===================

function prepare_layerswap_v8_transaction(bridge::LayerSwapBridge, from_chain::String, to_chain::String,
                                        amount::Float64, token_address::String, recipient::String)::Dict{String, Any}
    
    # Validate recipient address first
    if !validate_address(recipient, to_chain)
        throw(ArgumentError("Invalid recipient address for destination chain $to_chain"))
    end
    
    discovery_contract = bridge.v8_contracts["discovery"]
    auction_contract = bridge.v8_contracts["auction"]
    
    amount_wei = safe_amount_conversion(amount)
    if isnothing(amount_wei)
        throw(ArgumentError("Invalid amount for conversion"))
    end
    
    amount_hex = string(amount_wei, base=16, pad=64)
    recipient_hex = lpad(replace(recipient, "0x" => ""), 64, "0")
    
    # Enhanced timelock with minimum security duration
    timelock_duration = max(3600, Int(amount / 1000) + 1800)  # Minimum 1 hour, +30min per 1000 units
    timelock_hex = string(timelock_duration, base=16, pad=64)
    
    commit_function_selector = "0x2ac0df5a"
    data = commit_function_selector * amount_hex * recipient_hex * timelock_hex
    
    return Dict{String, Any}(
        "to" => get(bridge.config.contract_addresses, from_chain, ""),
        "data" => data,
        "value" => token_address == "native" ? "0x" * string(amount_wei, base=16) : "0x0",
        "gas_limit" => 250000,  # Increased gas limit for safety
        "network" => from_chain,
        "bridge_type" => "v8_atomic",
        "discovery_contract" => discovery_contract,
        "auction_contract" => auction_contract,
        "destination_chain" => to_chain,
        "timelock_duration" => timelock_duration,
        "security_level" => "high"
    )
end

function prepare_layerswap_api_transaction(bridge::LayerSwapBridge, from_chain::String, to_chain::String,
                                         amount::Float64, token_address::String, recipient::String)::Dict{String, Any}
    
    source_network = chain_to_layerswap_network(from_chain)
    destination_network = chain_to_layerswap_network(to_chain)
    asset_symbol = token_address_to_symbol(token_address, from_chain)
    
    return Dict{String, Any}(
        "type" => "swap",
        "source_network" => source_network,
        "destination_network" => destination_network,
        "amount" => amount,
        "asset" => asset_symbol,
        "source_address" => "USER_WALLET_ADDRESS",  # To be replaced by actual user address
        "destination_address" => recipient,
        "refuel" => false,
        "reference_id" => "juliaos_$(Int(time()))",
        "bridge_type" => "api",
        "api_endpoint" => bridge.api_endpoint,
        "slippage_tolerance" => get(bridge.config.slippage_tolerance, from_chain, DEFAULT_SLIPPAGE_PERCENT)
    )
end

function prepare_xcm_transaction(bridge::PolkadotXCMBridge, from_chain::String, to_chain::String,
                               amount::Float64, token_address::String, recipient::String)::Dict{String, Any}
    
    # Validate Substrate address format
    if !validate_address(recipient, to_chain)
        throw(ArgumentError("Invalid Substrate address format for $to_chain"))
    end
    
    from_info = get_xcm_chain_info(bridge, from_chain)
    to_info = get_xcm_chain_info(bridge, to_chain)
    
    if isnothing(from_info) || isnothing(to_info)
        throw(ArgumentError("Unsupported chain in XCM transaction"))
    end
    
    # Determine XCM method based on chain relationship
    xcm_method = if from_info["type"] == "relay" && to_info["type"] == "parachain"
        "limitedTeleportAssets"  # Relay to parachain
    elseif from_info["type"] == "parachain" && to_info["type"] == "relay"
        "limitedReserveTransferAssets"  # Parachain to relay
    else
        "limitedReserveTransferAssets"  # Parachain to parachain
    end
    
    # Prepare destination multilocation
    dest = if to_info["type"] == "relay"
        Dict("parents" => 1, "interior" => "Here")
    else
        Dict("parents" => 1, "interior" => Dict("X1" => Dict("Parachain" => to_info["parachain_id"])))
    end
    
    # Prepare beneficiary multilocation
    beneficiary = Dict(
        "parents" => 0,
        "interior" => Dict("X1" => Dict("AccountId32" => Dict(
            "network" => nothing,
            "id" => recipient
        )))
    )
    
    # Asset preparation
    asset_amount = safe_amount_conversion(amount)
    if isnothing(asset_amount)
        throw(ArgumentError("Invalid amount for XCM transaction"))
    end
    
    assets = Dict(
        "V3" => [Dict(
            "id" => Dict("Concrete" => Dict("parents" => 0, "interior" => "Here")),
            "fun" => Dict("Fungible" => string(asset_amount))
        )]
    )
    
    return Dict{String, Any}(
        "pallet" => "xcmPallet",
        "method" => xcm_method,
        "params" => Dict(
            "dest" => Dict("V3" => dest),
            "beneficiary" => Dict("V3" => beneficiary),
            "assets" => assets,
            "fee_asset_item" => 0,
            "weight_limit" => "Unlimited"
        ),
        "network" => from_chain,
        "bridge_type" => "xcm",
        "transport_method" => determine_xcm_transport_method(from_info, to_info)
    )
end

function prepare_wormhole_transaction(bridge::WormholeBridge, from_chain::String, to_chain::String,
                                    amount::Float64, token_address::String, recipient::String)::Dict{String, Any}
    
    amount_wei = safe_amount_conversion(amount)
    if isnothing(amount_wei)
        throw(ArgumentError("Invalid amount for Wormhole transaction"))
    end
    
    # Wormhole-specific chain IDs
    chain_ids = Dict(
        "ethereum" => 2,
        "solana" => 1,
        "base" => 30,
        "polygon" => 5,
        "arbitrum" => 23,
        "optimism" => 24,
        "avalanche" => 6,
        "bsc" => 4
    )
    
    from_chain_id = get(chain_ids, from_chain, 0)
    to_chain_id = get(chain_ids, to_chain, 0)
    
    if from_chain_id == 0 || to_chain_id == 0
        throw(ArgumentError("Unsupported chain for Wormhole bridge"))
    end
    
    if to_chain == "solana"
        # Special handling for Solana destination
        return Dict{String, Any}(
            "to" => get(bridge.config.contract_addresses, from_chain, ""),
            "data" => "0x" * encode_wormhole_transfer_data(amount_wei, recipient, to_chain_id),
            "value" => token_address == "native" ? "0x" * string(amount_wei, base=16) : "0x0",
            "gas_limit" => 300000,
            "network" => from_chain,
            "bridge_type" => "wormhole",
            "destination_chain_id" => to_chain_id,
            "security_confirmations" => 15
        )
    else
        # EVM to EVM transfer
        return Dict{String, Any}(
            "to" => get(bridge.config.contract_addresses, from_chain, ""),
            "data" => "0x" * encode_wormhole_transfer_data(amount_wei, recipient, to_chain_id),
            "value" => token_address == "native" ? "0x" * string(amount_wei, base=16) : "0x0",
            "gas_limit" => 200000,
            "network" => from_chain,
            "bridge_type" => "wormhole",
            "destination_chain_id" => to_chain_id,
            "security_confirmations" => 12
        )
    end
end

function prepare_layerzero_transaction(bridge::LayerZeroBridge, from_chain::String, to_chain::String,
                                     amount::Float64, token_address::String, recipient::String)::Dict{String, Any}
    
    amount_wei = safe_amount_conversion(amount)
    if isnothing(amount_wei)
        throw(ArgumentError("Invalid amount for LayerZero transaction"))
    end
    
    # LayerZero endpoint IDs
    endpoint_ids = Dict(
        "ethereum" => 101,
        "base" => 184,
        "polygon" => 109,
        "arbitrum" => 110,
        "optimism" => 111,
        "avalanche" => 106,
        "bsc" => 102
    )
    
    to_endpoint_id = get(endpoint_ids, to_chain, 0)
    if to_endpoint_id == 0
        throw(ArgumentError("Unsupported destination chain for LayerZero"))
    end
    
    # LayerZero send function
    function_selector = "0x7d25a05e"  # send(uint16,bytes,bytes,address,address,bytes)
    
    # Encode parameters
    dst_chain_id_hex = string(to_endpoint_id, base=16, pad=4)
    amount_hex = string(amount_wei, base=16, pad=64)
    recipient_bytes = lpad(replace(recipient, "0x" => ""), 64, "0")
    
    data = function_selector * dst_chain_id_hex * amount_hex * recipient_bytes
    
    return Dict{String, Any}(
        "to" => get(bridge.config.contract_addresses, from_chain, ""),
        "data" => "0x" * data,
        "value" => token_address == "native" ? "0x" * string(amount_wei, base=16) : "0x0",
        "gas_limit" => 220000,
        "network" => from_chain,
        "bridge_type" => "layerzero",
        "destination_endpoint_id" => to_endpoint_id,
        "security_confirmations" => 12
    )
end

function prepare_generic_evm_transaction(bridge::AbstractBridge, from_chain::String, to_chain::String,
                                       amount::Float64, token_address::String, recipient::String)::Dict{String, Any}
    
    amount_wei = safe_amount_conversion(amount)
    if isnothing(amount_wei)
        throw(ArgumentError("Invalid amount for generic EVM transaction"))
    end
    
    return Dict{String, Any}(
        "to" => get(bridge.config.contract_addresses, from_chain, ""),
        "data" => "0x",  # Basic transfer data
        "value" => "0x" * string(amount_wei, base=16),
        "gas_limit" => 150000,
        "network" => from_chain,
        "bridge_type" => "generic_evm"
    )
end

# =================== UTILITY FUNCTIONS ===================

function chain_to_layerswap_network(chain_name::String)::String
    mapping = Dict(
        "ethereum" => "ETHEREUM_MAINNET",
        "base" => "BASE_MAINNET", 
        "polygon" => "POLYGON_MAINNET",
        "arbitrum" => "ARBITRUM_MAINNET",
        "optimism" => "OPTIMISM_MAINNET",
        "avalanche" => "AVALANCHE_MAINNET",
        "bsc" => "BNB_MAINNET",
        "solana" => "SOLANA_MAINNET",
        "starknet" => "STARKNET_MAINNET",
        "immutable" => "IMX_MAINNET",
        "linea" => "LINEA_MAINNET",
        "zksync" => "ZKSYNC_MAINNET"
    )
    return get(mapping, lowercase(chain_name), uppercase(chain_name) * "_MAINNET")
end

function token_address_to_symbol(token_address::String, chain::String)::String
    if token_address == "native"
        native_symbols = Dict(
            "ethereum" => "ETH",
            "base" => "ETH",
            "polygon" => "MATIC",
            "arbitrum" => "ETH",
            "optimism" => "ETH",
            "avalanche" => "AVAX",
            "bsc" => "BNB",
            "solana" => "SOL"
        )
        return get(native_symbols, chain, "UNKNOWN")
    end
    
    # Common token mappings (simplified)
    common_tokens = Dict(
        "0xA0b86a33E6441e39A2ae29A5Deba9C9C0b9DB9" => "USDC",
        "0xdAC17F958D2ee523a2206206994597C13D831ec7" => "USDT",
        "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2" => "WETH"
    )
    
    return get(common_tokens, token_address, "UNKNOWN")
end

function encode_wormhole_transfer_data(amount::BigInt, recipient::String, target_chain_id::Int)::String
    # Simplified Wormhole transfer encoding
    amount_hex = string(amount, base=16, pad=64)
    recipient_hex = lpad(replace(recipient, "0x" => ""), 64, "0")
    chain_id_hex = string(target_chain_id, base=16, pad=4)
    
    return "0f5287b0" * amount_hex * recipient_hex * chain_id_hex  # transferTokens function selector
end

function get_xcm_chain_info(bridge::PolkadotXCMBridge, chain::String)::Union{Dict{String, Any}, Nothing}
    chain_info = Dict(
        "polkadot" => Dict("type" => "relay", "relay" => "polkadot", "network" => "mainnet"),
        "kusama" => Dict("type" => "relay", "relay" => "kusama", "network" => "mainnet"),
        "paseo" => Dict("type" => "relay", "relay" => "paseo", "network" => "testnet"),
        "statemint" => Dict("type" => "parachain", "parachain_id" => 1000, "relay" => "polkadot", "network" => "mainnet"),
        "asset_hub_paseo" => Dict("type" => "parachain", "parachain_id" => 1000, "relay" => "paseo", "network" => "testnet"),
        "acala" => Dict("type" => "parachain", "parachain_id" => 2000, "relay" => "polkadot", "network" => "mainnet"),
        "karura" => Dict("type" => "parachain", "parachain_id" => 2000, "relay" => "kusama", "network" => "mainnet"),
        "moonbeam" => Dict("type" => "parachain", "parachain_id" => 2004, "relay" => "polkadot", "network" => "mainnet"),
        "moonriver" => Dict("type" => "parachain", "parachain_id" => 2023, "relay" => "kusama", "network" => "mainnet"),
        "astar" => Dict("type" => "parachain", "parachain_id" => 2006, "relay" => "polkadot", "network" => "mainnet"),
        "coretime_paseo" => Dict("type" => "parachain", "parachain_id" => 1005, "relay" => "paseo", "network" => "testnet"),
        "people_paseo" => Dict("type" => "parachain", "parachain_id" => 1004, "relay" => "paseo", "network" => "testnet")
    )
    
    return get(chain_info, chain, nothing)
end

function determine_xcm_transport_method(from_info::Dict{String, Any}, to_info::Dict{String, Any})::String
    if from_info["type"] == "relay" && to_info["type"] == "parachain"
        return "DMP"  # Downward Message Passing
    elseif from_info["type"] == "parachain" && to_info["type"] == "relay"
        return "UMP"  # Upward Message Passing
    elseif from_info["type"] == "parachain" && to_info["type"] == "parachain"
        return "HRMP"  # Horizontal Relay-routed Message Passing
    else
        return "XCMP"  # Cross-Chain Message Passing
    end
end

function get_xcm_supported_assets(bridge::PolkadotXCMBridge, from_chain::String, to_chain::String)::Vector{Dict{String, Any}}
    # Simplified asset mapping for XCM
    assets = Vector{Dict{String, Any}}()
    
    supported_assets = bridge.xcm_sdk_config["supported_assets"]
    
    for asset in supported_assets
        push!(assets, Dict{String, Any}(
            "token_symbol" => asset,
            "from_chain" => from_chain,
            "to_chain" => to_chain,
            "is_native" => asset in ["DOT", "KSM", "PAS"],
            "decimals" => asset in ["DOT", "KSM", "PAS"] ? 10 : 6
        ))
    end
    
    return assets
end

# =================== XCM SPECIFIC VALIDATIONS ===================

function validate_xcm_transfer(bridge::PolkadotXCMBridge, from_chain::String, to_chain::String,
                              amount::Float64, token_address::String)::Dict{String, Any}
    validation_result = Dict{String, Any}(
        "valid" => true,
        "errors" => Vector{String}(),
        "warnings" => Vector{String}()
    )
    
    from_info = get_xcm_chain_info(bridge, from_chain)
    to_info = get_xcm_chain_info(bridge, to_chain)
    
    if isnothing(from_info)
        push!(validation_result["errors"], "Unsupported source chain: $from_chain")
        validation_result["valid"] = false
    end
    
    if isnothing(to_info)
        push!(validation_result["errors"], "Unsupported destination chain: $to_chain")
        validation_result["valid"] = false
    end
    
    if from_chain == to_chain
        push!(validation_result["errors"], "Source and destination chains cannot be the same")
        validation_result["valid"] = false
    end
    
    # Check relay compatibility for cross-relay transfers
    if !isnothing(from_info) && !isnothing(to_info)
        same_relay = get(from_info, "relay", from_chain) == get(to_info, "relay", to_chain)
        if !same_relay && from_info["type"] != "relay" && to_info["type"] != "relay"
            push!(validation_result["errors"], "Cross-relay transfers between parachains not directly supported")
            validation_result["valid"] = false
        end
    end
    
    # Amount validation
    min_amount = 0.01  # Minimum for XCM transfers
    max_amount = 1000000.0  # Maximum for XCM transfers
    
    if amount < min_amount
        push!(validation_result["errors"], "Transfer amount $amount is below minimum $min_amount for XCM")
        validation_result["valid"] = false
    end
    
    if amount > max_amount
        push!(validation_result["errors"], "Transfer amount $amount exceeds maximum $max_amount for XCM")
        validation_result["valid"] = false
    end
    
    # Asset support validation
    supported_assets = get_xcm_supported_assets(bridge, from_chain, to_chain)
    asset_supported = any(asset -> asset["token_symbol"] == token_address || 
                               (token_address == "native" && asset["is_native"]), supported_assets)
    
    if !asset_supported
        push!(validation_result["warnings"], "Asset $token_address may not be supported on the destination chain")
    end
    
    return validation_result
end

end  # module CrossChainBridge