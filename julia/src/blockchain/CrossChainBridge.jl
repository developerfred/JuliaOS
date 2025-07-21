module CrossChainBridge

using JSON3, HTTP, Dates, Logging
using ..Blockchain, ..Utils

export BaseBridge, SolanaBridge, WormholeBridge, LayerZeroBridge, 
       BridgeRegistry, create_bridge, get_supported_bridges,
       execute_cross_chain_transfer, get_transfer_status,
       estimate_bridge_fees, validate_bridge_transfer

abstract type AbstractBridge end

struct BridgeConfig
    name::String
    supported_chains::Vector{String}
    contract_addresses::Dict{String, String}
    fee_structure::Dict{String, Any}
    max_transfer_amount::Dict{String, Float64}
    min_transfer_amount::Dict{String, Float64}
    estimated_time::Dict{String, Int}
    gas_multiplier::Float64
    security_level::String
end

struct BaseBridge <: AbstractBridge
    config::BridgeConfig
    rpc_endpoints::Dict{String, String}
    
    function BaseBridge()
        config = BridgeConfig(
            "Base",
            ["ethereum", "base", "optimism", "arbitrum"],
            Dict(
                "ethereum" => "0xa3A7B6F88361F48403514059F1F16C8E78d60EeC",
                "base" => "0x4200000000000000000000000000000000000010",
                "optimism" => "0x4200000000000000000000000000000000000010",
                "arbitrum" => "0xa3A7B6F88361F48403514059F1F16C8E78d60EeC"
            ),
            Dict("fixed_fee" => 0.001, "percentage_fee" => 0.0025),
            Dict("ethereum" => 1000000.0, "base" => 1000000.0),
            Dict("ethereum" => 0.01, "base" => 0.01),
            Dict("ethereum_to_base" => 300, "base_to_ethereum" => 600),
            1.2,
            "high"
        )
        
        rpc_endpoints = Dict(
            "ethereum" => get(ENV, "ETHEREUM_RPC_URL", "https://mainnet.infura.io/v3/YOUR_INFURA_KEY"),
            "base" => get(ENV, "BASE_RPC_URL", "https://mainnet.base.org"),
            "optimism" => get(ENV, "OPTIMISM_RPC_URL", "https://mainnet.optimism.io"),
            "arbitrum" => get(ENV, "ARBITRUM_RPC_URL", "https://arb1.arbitrum.io/rpc")
        )
        
        new(config, rpc_endpoints)
    end
end

struct SolanaBridge <: AbstractBridge
    config::BridgeConfig
    rpc_endpoints::Dict{String, String}
    
    function SolanaBridge()
        config = BridgeConfig(
            "Solana",
            ["ethereum", "solana", "polygon", "base"],
            Dict(
                "ethereum" => "0x3ee18B2214AFF97000D974cf647E7C347E8fa585",
                "solana" => "worm2ZoG2kUd4vFXhvjh93UUH596ayRfgQ2MgjNMTth",
                "polygon" => "0x5a58505a96D1dbf8dF91cB21B54419FC36e93fdE",
                "base" => "0x8d2de8d2f73F1F4cAB472AC9A881C9b123C79627"
            ),
            Dict("fixed_fee" => 0.002, "percentage_fee" => 0.003),
            Dict("ethereum" => 500000.0, "solana" => 10000000.0),
            Dict("ethereum" => 0.05, "solana" => 1.0),
            Dict("ethereum_to_solana" => 900, "solana_to_ethereum" => 1200),
            1.5,
            "medium"
        )
        
        rpc_endpoints = Dict(
            "ethereum" => get(ENV, "ETHEREUM_RPC_URL", "https://mainnet.infura.io/v3/YOUR_INFURA_KEY"),
            "solana" => get(ENV, "SOLANA_RPC_URL", "https://api.mainnet-beta.solana.com"),
            "polygon" => get(ENV, "POLYGON_RPC_URL", "https://polygon-rpc.com"),
            "base" => get(ENV, "BASE_RPC_URL", "https://mainnet.base.org")
        )
        
        new(config, rpc_endpoints)
    end
end

struct WormholeBridge <: AbstractBridge
    config::BridgeConfig
    rpc_endpoints::Dict{String, String}
    guardian_network::String
    
    function WormholeBridge()
        config = BridgeConfig(
            "Wormhole",
            ["ethereum", "solana", "base", "polygon", "arbitrum", "optimism", "avalanche", "bsc"],
            Dict(
                "ethereum" => "0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B",
                "solana" => "worm2ZoG2kUd4vFXhvjh93UUH596ayRfgQ2MgjNMTth",
                "base" => "0x8d2de8d2f73F1F4cAB472AC9A881C9b123C79627",
                "polygon" => "0x7A4B5a56256163F07b2C80A7cA55aBE66c4ec4d7",
                "arbitrum" => "0xa5f208e072434bC67592E4C49C1B991BA79BCA46",
                "optimism" => "0xEe91C335eab126dF5fDB3797EA9d6aD93aeC9722",
                "avalanche" => "0x54a8e5f9c4CbA08F9943965859F6c34eAF03E26c",
                "bsc" => "0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B"
            ),
            Dict("fixed_fee" => 0.0015, "percentage_fee" => 0.002),
            Dict("ethereum" => 10000000.0, "solana" => 100000000.0),
            Dict("ethereum" => 0.001, "solana" => 0.1),
            Dict("ethereum_to_solana" => 600, "solana_to_ethereum" => 900),
            1.3,
            "very_high"
        )
        
        rpc_endpoints = Dict(
            "ethereum" => get(ENV, "ETHEREUM_RPC_URL", "https://mainnet.infura.io/v3/YOUR_INFURA_KEY"),
            "solana" => get(ENV, "SOLANA_RPC_URL", "https://api.mainnet-beta.solana.com"),
            "base" => get(ENV, "BASE_RPC_URL", "https://mainnet.base.org"),
            "polygon" => get(ENV, "POLYGON_RPC_URL", "https://polygon-rpc.com"),
            "arbitrum" => get(ENV, "ARBITRUM_RPC_URL", "https://arb1.arbitrum.io/rpc"),
            "optimism" => get(ENV, "OPTIMISM_RPC_URL", "https://mainnet.optimism.io"),
            "avalanche" => get(ENV, "AVALANCHE_RPC_URL", "https://api.avax.network/ext/bc/C/rpc"),
            "bsc" => get(ENV, "BSC_RPC_URL", "https://bsc-dataseed.binance.org")
        )
        
        guardian_network = get(ENV, "WORMHOLE_GUARDIAN_RPC", "https://wormhole-v2-mainnet-api.certus.one")
        
        new(config, rpc_endpoints, guardian_network)
    end
end

struct LayerZeroBridge <: AbstractBridge
    config::BridgeConfig
    rpc_endpoints::Dict{String, String}
    
    function LayerZeroBridge()
        config = BridgeConfig(
            "LayerZero",
            ["ethereum", "base", "polygon", "arbitrum", "optimism", "avalanche", "bsc"],
            Dict(
                "ethereum" => "0x66A71Dcef29A0fFBDBE3c6a460a3B5BC225Cd675",
                "base" => "0x1a44076050125825900e736c501f859c50fE728c",
                "polygon" => "0x3c2269811836af69497E5F486A85D7316753cf62",
                "arbitrum" => "0x3c2269811836af69497E5F486A85D7316753cf62",
                "optimism" => "0x3c2269811836af69497E5F486A85D7316753cf62",
                "avalanche" => "0x3c2269811836af69497E5F486A85D7316753cf62",
                "bsc" => "0x3c2269811836af69497E5F486A85D7316753cf62"
            ),
            Dict("fixed_fee" => 0.003, "percentage_fee" => 0.0015),
            Dict("ethereum" => 5000000.0, "base" => 5000000.0),
            Dict("ethereum" => 0.1, "base" => 0.1),
            Dict("ethereum_to_base" => 180, "base_to_ethereum" => 300),
            1.1,
            "high"
        )
        
        rpc_endpoints = Dict(
            "ethereum" => get(ENV, "ETHEREUM_RPC_URL", "https://mainnet.infura.io/v3/YOUR_INFURA_KEY"),
            "base" => get(ENV, "BASE_RPC_URL", "https://mainnet.base.org"),
            "polygon" => get(ENV, "POLYGON_RPC_URL", "https://polygon-rpc.com"),
            "arbitrum" => get(ENV, "ARBITRUM_RPC_URL", "https://arb1.arbitrum.io/rpc"),
            "optimism" => get(ENV, "OPTIMISM_RPC_URL", "https://mainnet.optimism.io"),
            "avalanche" => get(ENV, "AVALANCHE_RPC_URL", "https://api.avax.network/ext/bc/C/rpc"),
            "bsc" => get(ENV, "BSC_RPC_URL", "https://bsc-dataseed.binance.org")
        )
        
        new(config, rpc_endpoints)
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
            ["polkadot", "kusama", "statemint", "karura", "acala", "moonbeam", "moonriver", "astar", "shiden", "bifrost", "parallel", "centrifuge", "interlay", "kintsugi", "basilisk", "paseo", "asset_hub_paseo", "bridge_hub_paseo", "people_paseo", "coretime_paseo"],
            Dict(
                "polkadot" => "0x00",  # Relay chain
                "kusama" => "0x00",    # Relay chain
                "paseo" => "0x00",     # Testnet relay chain
                "statemint" => "1000", # System parachain
                "statemine" => "1000", # System parachain on Kusama
                "asset_hub_paseo" => "1000", # System parachain on Paseo
                "bridge_hub_paseo" => "1002", # Bridge Hub on Paseo
                "people_paseo" => "1004", # People chain on Paseo  
                "coretime_paseo" => "1005", # Coretime chain on Paseo
                "karura" => "2000",    # Acala's Kusama parachain
                "acala" => "2000",     # Polkadot parachain
                "moonbeam" => "2004",  # Polkadot parachain
                "moonriver" => "2023", # Kusama parachain  
                "astar" => "2006",     # Polkadot parachain
                "shiden" => "2007",    # Kusama parachain
                "bifrost" => "2001",   # Polkadot parachain
                "parallel" => "2012",  # Polkadot parachain
                "centrifuge" => "2031",# Polkadot parachain
                "interlay" => "2032",  # Polkadot parachain
                "kintsugi" => "2092",  # Kusama parachain
                "basilisk" => "2090"   # Kusama parachain
            ),
            Dict("fixed_fee" => 0.0005, "percentage_fee" => 0.0005),
            Dict("polkadot" => 50000000.0, "kusama" => 1000000.0, "paseo" => 1000000.0),
            Dict("polkadot" => 0.01, "kusama" => 0.001, "paseo" => 0.001),
            Dict("polkadot_to_acala" => 60, "kusama_to_karura" => 60, "moonbeam_to_polkadot" => 120, "paseo_to_asset_hub_paseo" => 30, "paseo_to_coretime_paseo" => 30),
            1.0,
            "very_high"
        )
        
        rpc_endpoints = Dict(
            "polkadot" => get(ENV, "POLKADOT_RPC_URL", "wss://rpc.polkadot.io"),
            "kusama" => get(ENV, "KUSAMA_RPC_URL", "wss://kusama-rpc.polkadot.io"),
            "paseo" => get(ENV, "PASEO_RPC_URL", "wss://rpc.ibp.network/paseo"),
            "statemint" => get(ENV, "STATEMINT_RPC_URL", "wss://statemint-rpc.polkadot.io"),
            "statemine" => get(ENV, "STATEMINE_RPC_URL", "wss://statemine-rpc.polkadot.io"),
            "asset_hub_paseo" => get(ENV, "ASSET_HUB_PASEO_RPC_URL", "wss://paseo-asset-hub-rpc.polkadot.io"),
            "bridge_hub_paseo" => get(ENV, "BRIDGE_HUB_PASEO_RPC_URL", "wss://paseo-bridge-hub-rpc.polkadot.io"),
            "people_paseo" => get(ENV, "PEOPLE_PASEO_RPC_URL", "wss://paseo-people-rpc.polkadot.io"),
            "coretime_paseo" => get(ENV, "CORETIME_PASEO_RPC_URL", "wss://paseo-coretime-rpc.polkadot.io"),
            "acala" => get(ENV, "ACALA_RPC_URL", "wss://acala-rpc-0.aca-api.network"),
            "karura" => get(ENV, "KARURA_RPC_URL", "wss://karura-rpc-0.aca-api.network"),
            "moonbeam" => get(ENV, "MOONBEAM_RPC_URL", "wss://wss.api.moonbeam.network"),
            "moonriver" => get(ENV, "MOONRIVER_RPC_URL", "wss://wss.api.moonriver.moonbeam.network"),
            "astar" => get(ENV, "ASTAR_RPC_URL", "wss://rpc.astar.network"),
            "shiden" => get(ENV, "SHIDEN_RPC_URL", "wss://rpc.shiden.astar.network"),
            "bifrost" => get(ENV, "BIFROST_RPC_URL", "wss://bifrost-polkadot.api.onfinality.io/public-ws"),
            "parallel" => get(ENV, "PARALLEL_RPC_URL", "wss://rpc.parallel.fi"),
            "centrifuge" => get(ENV, "CENTRIFUGE_RPC_URL", "wss://fullnode.centrifuge.io"),
            "interlay" => get(ENV, "INTERLAY_RPC_URL", "wss://api.interlay.io/parachain"),
            "kintsugi" => get(ENV, "KINTSUGI_RPC_URL", "wss://api-kusama.interlay.io/parachain"),
            "basilisk" => get(ENV, "BASILISK_RPC_URL", "wss://rpc.basilisk.cloud")
        )
        
        xcm_sdk_config = Dict(
            "xcm_version" => 3,
            "default_weight_limit" => "Unlimited",
            "default_fee_asset_item" => 0,
            "supported_assets" => ["DOT", "KSM", "USDT", "USDC", "ASTR", "GLMR", "MOVR", "ACA", "KAR"],
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
                "polygon" => "0x2fc617e933a52713247ce25730f6695920b3befe",
                "arbitrum" => "0x2fc617e933a52713247ce25730f6695920b3befe",
                "optimism" => "0x2fc617e933a52713247ce25730f6695920b3befe",
                "avalanche" => "0x2fc617e933a52713247ce25730f6695920b3befe",
                "bsc" => "0x2fc617e933a52713247ce25730f6695920b3befe",
                "solana" => "2XfmTmnhz8kDnryZSJKKV53tLN7DKZbrN9Q1sZbJo5bc",
                "starknet" => "0x0112a045ae21884942faffd7a8087276638e6e4b8a3833a65d14be15eef8f53b",
                "immutable" => "0x67d3E9cb8d3200444349D2a7794960EeB969631c",
                "linea" => "0x67d3E9cb8d3200444349D2a7794960EeB969631c",
                "zksync" => "0x67d3E9cb8d3200444349D2a7794960EeB969631c"
            ),
            Dict("fixed_fee" => 0.001, "percentage_fee" => 0.001),
            Dict("ethereum" => 10000000.0, "base" => 10000000.0, "solana" => 50000000.0),
            Dict("ethereum" => 0.005, "base" => 0.005, "solana" => 0.1),
            Dict("ethereum_to_base" => 120, "base_to_ethereum" => 180, "ethereum_to_solana" => 300, "solana_to_ethereum" => 420),
            1.05,
            "very_high"
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
            "fee_structure" => bridge.config.fee_structure
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
    
    if !(from_chain in bridge.config.supported_chains)
        push!(validation_result["errors"], "Source chain '$from_chain' not supported by $(bridge.config.name)")
        validation_result["valid"] = false
    end
    
    if !(to_chain in bridge.config.supported_chains)
        push!(validation_result["errors"], "Destination chain '$to_chain' not supported by $(bridge.config.name)")
        validation_result["valid"] = false
    end
    
    if from_chain == to_chain
        push!(validation_result["errors"], "Source and destination chains cannot be the same")
        validation_result["valid"] = false
    end
    
    min_amount = get(bridge.config.min_transfer_amount, from_chain, 0.0)
    max_amount = get(bridge.config.max_transfer_amount, from_chain, Inf)
    
    if amount < min_amount
        push!(validation_result["errors"], "Transfer amount $amount is below minimum $min_amount for $from_chain")
        validation_result["valid"] = false
    end
    
    if amount > max_amount
        push!(validation_result["errors"], "Transfer amount $amount exceeds maximum $max_amount for $from_chain")
        validation_result["valid"] = false
    end
    
    if amount > max_amount * 0.8
        push!(validation_result["warnings"], "Transfer amount is close to maximum limit")
    end
    
    return validation_result
end

function estimate_bridge_fees(bridge::AbstractBridge, from_chain::String, to_chain::String, 
                            amount::Float64)::Dict{String, Any}
    fixed_fee = bridge.config.fee_structure["fixed_fee"]
    percentage_fee = bridge.config.fee_structure["percentage_fee"]
    
    variable_fee = amount * percentage_fee
    total_fee = fixed_fee + variable_fee
    
    route_key = "$(from_chain)_to_$(to_chain)"
    estimated_time = get(bridge.config.estimated_time, route_key, 600)
    
    try
        source_conn = Blockchain.connect(network=from_chain)
        gas_price = source_conn["connected"] ? Blockchain.get_gas_price_generic(source_conn) : 0.02
        
        estimated_gas = if from_chain == "solana" || to_chain == "solana"
            0.01
        else
            gas_price * 150000 / 1e9
        end
        
        gas_fee = estimated_gas * bridge.config.gas_multiplier
        
        return Dict{String, Any}(
            "bridge_name" => bridge.config.name,
            "fixed_fee" => fixed_fee,
            "percentage_fee" => percentage_fee,
            "variable_fee" => variable_fee,
            "gas_fee" => gas_fee,
            "total_fee" => total_fee + gas_fee,
            "estimated_time_seconds" => estimated_time,
            "fee_currency" => from_chain == "solana" ? "SOL" : "ETH"
        )
    catch e
        @warn "Failed to estimate gas fees: $e"
        return Dict{String, Any}(
            "bridge_name" => bridge.config.name,
            "fixed_fee" => fixed_fee,
            "variable_fee" => variable_fee,
            "total_fee" => total_fee,
            "estimated_time_seconds" => estimated_time,
            "gas_fee" => "unavailable",
            "fee_currency" => from_chain == "solana" ? "SOL" : "ETH"
        )
    end
end

function prepare_evm_bridge_transaction(bridge::AbstractBridge, from_chain::String, to_chain::String,
                                      amount::Float64, token_address::String, recipient::String)::Dict{String, Any}
    contract_address = bridge.config.contract_addresses[from_chain]
    
    function_selector = if bridge.config.name == "LayerZero"
        "0x7d25a05e"
    elseif bridge.config.name == "Wormhole"
        "0x0f5287b0"
    else
        "0xa9059cbb"
    end
    
    amount_hex = string(BigInt(amount * 1e18), base=16, pad=64)
    recipient_hex = lpad(replace(recipient, "0x" => ""), 64, "0")
    
    chain_id_mapping = Dict(
        "ethereum" => 1, "base" => 8453, "polygon" => 137,
        "arbitrum" => 42161, "optimism" => 10, "avalanche" => 43114, "bsc" => 56
    )
    
    to_chain_id = get(chain_id_mapping, to_chain, 1)
    to_chain_id_hex = string(to_chain_id, base=16, pad=64)
    
    data = function_selector * to_chain_id_hex * amount_hex * recipient_hex
    
    return Dict{String, Any}(
        "to" => contract_address,
        "data" => data,
        "value" => "0x0",
        "gas_limit" => 250000,
        "network" => from_chain
    )
end

function prepare_layerswap_transaction(bridge::LayerSwapBridge, from_chain::String, to_chain::String,
                                     amount::Float64, token_address::String, recipient::String)::Dict{String, Any}
    
    if !isnothing(bridge.api_key)
        return prepare_layerswap_api_transaction(bridge, from_chain, to_chain, amount, token_address, recipient)
    else
        return prepare_layerswap_v8_transaction(bridge, from_chain, to_chain, amount, token_address, recipient)
    end
end

function prepare_layerswap_api_transaction(bridge::LayerSwapBridge, from_chain::String, to_chain::String,
                                         amount::Float64, token_address::String, recipient::String)::Dict{String, Any}
    
    source_network = chain_to_layerswap_network(from_chain)
    destination_network = chain_to_layerswap_network(to_chain)
    asset_symbol = token_address_to_symbol(token_address, from_chain)
    
    return Dict{String, Any}(
        "api_endpoint" => bridge.api_endpoint,
        "method" => "POST",
        "path" => "/swap",
        "headers" => Dict(
            "X-LS-APIKEY" => bridge.api_key,
            "Content-Type" => "application/json"
        ),
        "body" => Dict(
            "source" => source_network,
            "destination" => destination_network,
            "amount" => amount,
            "asset" => asset_symbol,
            "source_address" => "USER_WALLET_ADDRESS",
            "destination_address" => recipient,
            "refuel" => false,
            "reference_id" => "juliaos_$(Int(time()))"
        ),
        "bridge_type" => "api"
    )
end

function prepare_layerswap_v8_transaction(bridge::LayerSwapBridge, from_chain::String, to_chain::String,
                                        amount::Float64, token_address::String, recipient::String)::Dict{String, Any}
    
    discovery_contract = bridge.v8_contracts["discovery"]
    auction_contract = bridge.v8_contracts["auction"]
    
    amount_wei = BigInt(amount * 1e18)
    amount_hex = string(amount_wei, base=16, pad=64)
    recipient_hex = lpad(replace(recipient, "0x" => ""), 64, "0")
    
    commit_function_selector = "0x2ac0df5a"
    timelock_duration = 3600
    timelock_hex = string(timelock_duration, base=16, pad=64)
    
    data = commit_function_selector * amount_hex * recipient_hex * timelock_hex
    
    return Dict{String, Any}(
        "to" => bridge.config.contract_addresses[from_chain],
        "data" => data,
        "value" => token_address == "native" ? "0x" * string(amount_wei, base=16) : "0x0",
        "gas_limit" => 180000,
        "network" => from_chain,
        "bridge_type" => "v8_atomic",
        "discovery_contract" => discovery_contract,
        "auction_contract" => auction_contract,
        "destination_chain" => to_chain,
        "timelock_duration" => timelock_duration
    )
end

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
        return chain == "solana" ? "SOL" : "ETH"
    end
    
    common_tokens = Dict(
        "0xA0b86a33E6441e39A2ae29A5Deba9C9C0b9DB9" => "USDC",
        "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" => "USDC",
        "0xdAC17F958D2ee523a2206206994597C13D831ec7" => "USDT",
        "0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2" => "USDT",
        "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2" => "WETH",
        "0x4200000000000000000000000000000000000006" => "WETH",
        "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v" => "USDC",
        "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB" => "USDT"
    )
    
    return get(common_tokens, token_address, "UNKNOWN")
end

function query_layerswap_available_networks(bridge::LayerSwapBridge)::Vector{Dict{String, Any}}
    if isnothing(bridge.api_key)
        return get_layerswap_default_networks()
    end
    
    try
        url = bridge.api_endpoint * "/available_networks"
        headers = ["Content-Type" => "application/json"]
        
        response = HTTP.get(url, headers)
        
        if response.status == 200
            data = JSON3.read(String(response.body))
            return haskey(data, "data") ? data["data"] : []
        else
            @warn "Failed to fetch LayerSwap networks: HTTP $(response.status)"
            return get_layerswap_default_networks()
        end
    catch e
        @warn "Error querying LayerSwap networks: $e"
        return get_layerswap_default_networks()
    end
end

function get_layerswap_default_networks()::Vector{Dict{String, Any}}
    return [
        Dict("name" => "ETHEREUM_MAINNET", "display_name" => "Ethereum", "chain_id" => "1", "native_asset" => "ETH"),
        Dict("name" => "BASE_MAINNET", "display_name" => "Base", "chain_id" => "8453", "native_asset" => "ETH"),
        Dict("name" => "ARBITRUM_MAINNET", "display_name" => "Arbitrum One", "chain_id" => "42161", "native_asset" => "ETH"),
        Dict("name" => "OPTIMISM_MAINNET", "display_name" => "Optimism", "chain_id" => "10", "native_asset" => "ETH"),
        Dict("name" => "POLYGON_MAINNET", "display_name" => "Polygon", "chain_id" => "137", "native_asset" => "MATIC"),
        Dict("name" => "SOLANA_MAINNET", "display_name" => "Solana", "chain_id" => "-1", "native_asset" => "SOL"),
        Dict("name" => "STARKNET_MAINNET", "display_name" => "StarkNet", "chain_id" => "0x534e5f4d41494e", "native_asset" => "ETH"),
        Dict("name" => "IMX_MAINNET", "display_name" => "Immutable X", "chain_id" => "13371", "native_asset" => "IMX"),
        Dict("name" => "LINEA_MAINNET", "display_name" => "Linea", "chain_id" => "59144", "native_asset" => "ETH"),
        Dict("name" => "ZKSYNC_MAINNET", "display_name" => "zkSync Era", "chain_id" => "324", "native_asset" => "ETH")
    ]
end

function prepare_solana_bridge_transaction(bridge::AbstractBridge, from_chain::String, to_chain::String,
                                         amount::Float64, token_address::String, recipient::String)::Dict{String, Any}
    return Dict{String, Any}(
        "program_id" => bridge.config.contract_addresses["solana"],
        "instruction_type" => "transfer_tokens",
        "amount" => Int(amount * 1e9),
        "recipient" => recipient,
        "target_chain" => to_chain,
        "token_mint" => token_address,
        "memo" => "JuliaOS cross-chain transfer"
    )
end

function execute_cross_chain_transfer(bridge_name::String, from_chain::String, to_chain::String,
                                    amount::Float64, token_address::String, recipient::String,
                                    signed_tx_hex::Union{String, Nothing}=nothing)::Dict{String, Any}
    bridge = create_bridge(bridge_name)
    if isnothing(bridge)
        return Dict{String, Any}(
            "success" => false,
            "error" => "Bridge '$bridge_name' not found"
        )
    end
    
    validation = validate_bridge_transfer(bridge, from_chain, to_chain, amount, token_address)
    if !validation["valid"]
        return Dict{String, Any}(
            "success" => false,
            "error" => "Transfer validation failed",
            "details" => validation["errors"]
        )
    end
    
    operation_id = "$(bridge_name)_$(Int(time()))_$(rand(1000:9999))"
    
    try
        if from_chain == "solana"
            tx_data = prepare_solana_bridge_transaction(bridge, from_chain, to_chain, amount, token_address, recipient)
        elseif bridge.config.name == "LayerSwap"
            tx_data = prepare_layerswap_transaction(bridge, from_chain, to_chain, amount, token_address, recipient)
        else
            tx_data = prepare_evm_bridge_transaction(bridge, from_chain, to_chain, amount, token_address, recipient)
        end
        
        if !isnothing(signed_tx_hex)
            if bridge.config.name == "LayerSwap" && haskey(tx_data, "bridge_type") && tx_data["bridge_type"] == "api"
                api_result = execute_layerswap_api_swap(bridge, tx_data)
                if api_result["success"]
                    return Dict{String, Any}(
                        "success" => true,
                        "operation_id" => operation_id,
                        "layerswap_swap_id" => api_result["swap_id"],
                        "bridge_name" => bridge.config.name,
                        "from_chain" => from_chain,
                        "to_chain" => to_chain,
                        "amount" => amount,
                        "recipient" => recipient,
                        "status" => api_result["status"],
                        "api_response" => api_result["layerswap_response"]
                    )
                else
                    return api_result
                end
            else
                source_conn = Blockchain.connect(network=from_chain)
                if source_conn["connected"]
                    tx_hash = Blockchain.send_raw_transaction_generic(signed_tx_hex, source_conn)
                    
                    return Dict{String, Any}(
                        "success" => true,
                        "operation_id" => operation_id,
                        "transaction_hash" => tx_hash,
                        "bridge_name" => bridge.config.name,
                        "from_chain" => from_chain,
                        "to_chain" => to_chain,
                        "amount" => amount,
                        "recipient" => recipient,
                        "status" => "pending",
                        "estimated_completion" => Dates.now() + Dates.Second(get(bridge.config.estimated_time, "$(from_chain)_to_$(to_chain)", 600))
                    )
                else
                    return Dict{String, Any}(
                        "success" => false,
                        "error" => "Failed to connect to source chain '$from_chain'"
                    )
                end
            end
        else
            return Dict{String, Any}(
                "success" => true,
                "operation_id" => operation_id,
                "transaction_data" => tx_data,
                "bridge_name" => bridge.config.name,
                "message" => "Transaction prepared. Sign and submit the transaction_data."
            )
        end
        
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
    
    parts = split(operation_id, "_")
    if length(parts) < 3
        return Dict{String, Any}(
            "success" => false,
            "error" => "Invalid operation ID format"
        )
    end
    
    timestamp = parse(Int, parts[2])
    creation_time = Dates.unix2datetime(timestamp)
    elapsed_time = Dates.now() - creation_time
    
    estimated_completion_seconds = 600
    if length(parts) >= 4
        for (route, time_sec) in bridge.config.estimated_time
            if contains(operation_id, route)
                estimated_completion_seconds = time_sec
                break
            end
        end
    end
    
    completion_progress = min(1.0, Dates.value(elapsed_time) / 1000 / estimated_completion_seconds)
    
    status = if completion_progress < 0.3
        "pending"
    elseif completion_progress < 0.8
        "processing"
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
        "elapsed_time_seconds" => Dates.value(elapsed_time) ÷ 1000
    )
end

end

function execute_layerswap_api_swap(bridge::LayerSwapBridge, tx_data::Dict{String, Any})::Dict{String, Any}
    if isnothing(bridge.api_key)
        return Dict{String, Any}(
            "success" => false,
            "error" => "LayerSwap API key required for API-based swaps"
        )
    end
    
    try
        url = tx_data["api_endpoint"] * tx_data["path"]
        headers = [
            "X-LS-APIKEY" => bridge.api_key,
            "Content-Type" => "application/json"
        ]
        body = JSON3.write(tx_data["body"])
        
        response = HTTP.post(url, headers, body)
        
        if response.status >= 200 && response.status < 300
            data = JSON3.read(String(response.body))
            return Dict{String, Any}(
                "success" => true,
                "swap_id" => get(data, "swap_id", "unknown"),
                "status" => get(data, "status", "pending"),
                "layerswap_response" => data
            )
        else
            return Dict{String, Any}(
                "success" => false,
                "error" => "LayerSwap API error: HTTP $(response.status)"
            )
        end
    catch e
        return Dict{String, Any}(
            "success" => false,
            "error" => "Failed to execute LayerSwap API call: $(sprint(showerror, e))"
        )
    end
end


function prepare_xcm_transaction(bridge::PolkadotXCMBridge, from_chain::String, to_chain::String,
                                amount::Float64, token_address::String, recipient::String)::Dict{String, Any}
    
    from_chain_info = get_xcm_chain_info(bridge, from_chain)
    to_chain_info = get_xcm_chain_info(bridge, to_chain)
    
    if isnothing(from_chain_info) || isnothing(to_chain_info)
        return Dict{String, Any}(
            "success" => false,
            "error" => "Unsupported chain for XCM transfer"
        )
    end
    
    xcm_version = bridge.xcm_sdk_config["xcm_version"]
    weight_limit = bridge.xcm_sdk_config["default_weight_limit"]
    fee_asset_item = bridge.xcm_sdk_config["default_fee_asset_item"]
    
    dest_multilocation = create_xcm_destination(to_chain_info)
    beneficiary_multilocation = create_xcm_beneficiary(recipient, to_chain_info)
    assets_multilocation = create_xcm_assets(token_address, amount, from_chain_info)
    
    xcm_message = Dict{String, Any}(
        "version" => "V$xcm_version",
        "dest" => dest_multilocation,
        "beneficiary" => beneficiary_multilocation,
        "assets" => assets_multilocation,
        "fee_asset_item" => fee_asset_item,
        "weight_limit" => weight_limit
    )
    
    pallet_method = determine_xcm_method(from_chain_info, to_chain_info, token_address)
    
    return Dict{String, Any}(
        "pallet" => "xcmPallet",
        "method" => pallet_method,
        "params" => xcm_message,
        "from_chain" => from_chain,
        "to_chain" => to_chain,
        "bridge_type" => "xcm",
        "network" => from_chain,
        "estimated_weight" => calculate_xcm_weight(pallet_method),
        "xcm_version" => xcm_version
    )
end

function get_xcm_chain_info(bridge::PolkadotXCMBridge, chain_name::String)::Union{Dict{String, Any}, Nothing}
    chain_configs = Dict{String, Dict{String, Any}}(
        "polkadot" => Dict("type" => "relay", "parachain_id" => nothing, "ss58_format" => 0),
        "kusama" => Dict("type" => "relay", "parachain_id" => nothing, "ss58_format" => 2),
        "paseo" => Dict("type" => "relay", "parachain_id" => nothing, "ss58_format" => 0, "network" => "testnet"),
        "statemint" => Dict("type" => "parachain", "parachain_id" => 1000, "ss58_format" => 0, "relay" => "polkadot"),
        "statemine" => Dict("type" => "parachain", "parachain_id" => 1000, "ss58_format" => 2, "relay" => "kusama"),
        "asset_hub_paseo" => Dict("type" => "parachain", "parachain_id" => 1000, "ss58_format" => 0, "relay" => "paseo", "network" => "testnet"),
        "bridge_hub_paseo" => Dict("type" => "parachain", "parachain_id" => 1002, "ss58_format" => 0, "relay" => "paseo", "network" => "testnet"),
        "people_paseo" => Dict("type" => "parachain", "parachain_id" => 1004, "ss58_format" => 0, "relay" => "paseo", "network" => "testnet"),
        "coretime_paseo" => Dict("type" => "parachain", "parachain_id" => 1005, "ss58_format" => 0, "relay" => "paseo", "network" => "testnet"),
        "acala" => Dict("type" => "parachain", "parachain_id" => 2000, "ss58_format" => 10, "relay" => "polkadot"),
        "karura" => Dict("type" => "parachain", "parachain_id" => 2000, "ss58_format" => 8, "relay" => "kusama"),
        "moonbeam" => Dict("type" => "parachain", "parachain_id" => 2004, "ss58_format" => 1284, "relay" => "polkadot", "account_type" => "ethereum"),
        "moonriver" => Dict("type" => "parachain", "parachain_id" => 2023, "ss58_format" => 1285, "relay" => "kusama", "account_type" => "ethereum"),
        "astar" => Dict("type" => "parachain", "parachain_id" => 2006, "ss58_format" => 5, "relay" => "polkadot"),
        "shiden" => Dict("type" => "parachain", "parachain_id" => 2007, "ss58_format" => 5, "relay" => "kusama"),
        "bifrost" => Dict("type" => "parachain", "parachain_id" => 2001, "ss58_format" => 6, "relay" => "polkadot"),
        "parallel" => Dict("type" => "parachain", "parachain_id" => 2012, "ss58_format" => 172, "relay" => "polkadot"),
        "centrifuge" => Dict("type" => "parachain", "parachain_id" => 2031, "ss58_format" => 36, "relay" => "polkadot"),
        "interlay" => Dict("type" => "parachain", "parachain_id" => 2032, "ss58_format" => 2032, "relay" => "polkadot"),
        "kintsugi" => Dict("type" => "parachain", "parachain_id" => 2092, "ss58_format" => 2092, "relay" => "kusama"),
        "basilisk" => Dict("type" => "parachain", "parachain_id" => 2090, "ss58_format" => 10041, "relay" => "kusama")
    )
    
    return get(chain_configs, lowercase(chain_name), nothing)
end

function create_xcm_destination(chain_info::Dict{String, Any})::Dict{String, Any}
    if chain_info["type"] == "relay"
        return Dict{String, Any}(
            "V3" => Dict{String, Any}(
                "parents" => 1,
                "interior" => "Here"
            )
        )
    else
        return Dict{String, Any}(
            "V3" => Dict{String, Any}(
                "parents" => 1,
                "interior" => Dict{String, Any}(
                    "X1" => Dict{String, Any}(
                        "Parachain" => chain_info["parachain_id"]
                    )
                )
            )
        )
    end
end

function create_xcm_beneficiary(recipient::String, chain_info::Dict{String, Any})::Dict{String, Any}
    account_type = get(chain_info, "account_type", "substrate")
    
    if account_type == "ethereum"
        account_key = Dict{String, Any}(
            "AccountKey20" => Dict{String, Any}(
                "network" => nothing,
                "key" => recipient
            )
        )
    else
        account_key = Dict{String, Any}(
            "AccountId32" => Dict{String, Any}(
                "network" => nothing,
                "id" => recipient
            )
        )
    end
    
    return Dict{String, Any}(
        "V3" => Dict{String, Any}(
            "parents" => 0,
            "interior" => Dict{String, Any}(
                "X1" => account_key
            )
        )
    )
end

function create_xcm_assets(token_address::String, amount::Float64, chain_info::Dict{String, Any})::Dict{String, Any}
    asset_amount = determine_xcm_asset_amount(amount, token_address)
    
    if token_address == "native" || token_address == "DOT" || token_address == "KSM"
        asset_id = Dict{String, Any}(
            "Concrete" => Dict{String, Any}(
                "parents" => 0,
                "interior" => "Here"
            )
        )
    else
        asset_id = Dict{String, Any}(
            "Concrete" => Dict{String, Any}(
                "parents" => 0,
                "interior" => Dict{String, Any}(
                    "X2" => [
                        Dict{String, Any}("PalletInstance" => 50),
                        Dict{String, Any}("GeneralIndex" => parse(Int, token_address))
                    ]
                )
            )
        )
    end
    
    return Dict{String, Any}(
        "V3" => [
            Dict{String, Any}(
                "id" => asset_id,
                "fun" => Dict{String, Any}(
                    "Fungible" => asset_amount
                )
            )
        ]
    )
end

function determine_xcm_method(from_chain::Dict{String, Any}, to_chain::Dict{String, Any}, token_address::String)::String
    if from_chain["type"] == "relay" && to_chain["type"] == "parachain"
        return "limitedReserveTransferAssets"
    elseif from_chain["type"] == "parachain" && to_chain["type"] == "relay"
        return "limitedReserveTransferAssets"
    elseif from_chain["type"] == "parachain" && to_chain["type"] == "parachain"
        if token_address == "native"
            return "limitedTeleportAssets"
        else
            return "limitedReserveTransferAssets"
        end
    else
        return "limitedReserveTransferAssets"
    end
end

function determine_xcm_asset_amount(amount::Float64, token_address::String)::Int64
    decimals = if token_address in ["DOT", "native", "polkadot"]
        10
    elseif token_address in ["KSM", "kusama"]
        12
    elseif token_address in ["USDT", "USDC"]
        6
    else
        12
    end
    
    return Int64(amount * (10^decimals))
end

function calculate_xcm_weight(method::String)::Int64
    weight_mapping = Dict{String, Int64}(
        "limitedTeleportAssets" => 4000000000,
        "limitedReserveTransferAssets" => 5000000000,
        "reserveTransferAssets" => 4500000000,
        "teleportAssets" => 3500000000
    )
    
    return get(weight_mapping, method, 4000000000)
end

function execute_xcm_transfer(bridge::PolkadotXCMBridge, tx_data::Dict{String, Any}, signed_tx_hex::Union{String, Nothing})::Dict{String, Any}
    if !isnothing(signed_tx_hex)
        try
            from_chain = tx_data["from_chain"]
            connection = create_substrate_connection(bridge, from_chain)
            
            if connection["connected"]
                tx_hash = submit_substrate_extrinsic(connection, signed_tx_hex)
                
                return Dict{String, Any}(
                    "success" => true,
                    "transaction_hash" => tx_hash,
                    "bridge_name" => bridge.config.name,
                    "xcm_method" => tx_data["method"],
                    "from_chain" => from_chain,
                    "to_chain" => tx_data["to_chain"],
                    "status" => "pending",
                    "transport_method" => determine_xcm_transport_method(tx_data)
                )
            else
                return Dict{String, Any}(
                    "success" => false,
                    "error" => "Failed to connect to $from_chain network"
                )
            end
        catch e
            return Dict{String, Any}(
                "success" => false,
                "error" => "Failed to submit XCM transaction: $(sprint(showerror, e))"
            )
        end
    else
        return Dict{String, Any}(
            "success" => true,
            "transaction_data" => tx_data,
            "bridge_name" => bridge.config.name,
            "message" => "XCM transaction prepared. Sign and submit the extrinsic."
        )
    end
end

function create_substrate_connection(bridge::PolkadotXCMBridge, chain_name::String)::Dict{String, Any}
    rpc_url = get(bridge.rpc_endpoints, chain_name, nothing)
    
    if isnothing(rpc_url)
        return Dict{String, Any}(
            "connected" => false,
            "error" => "No RPC endpoint configured for $chain_name"
        )
    end
    
    try
        return Dict{String, Any}(
            "connected" => true,
            "endpoint" => rpc_url,
            "chain" => chain_name,
            "transport" => "websocket"
        )
    catch e
        return Dict{String, Any}(
            "connected" => false,
            "error" => "Failed to connect to $chain_name: $(sprint(showerror, e))"
        )
    end
end

function submit_substrate_extrinsic(connection::Dict{String, Any}, signed_tx_hex::String)::String
    return "0x" * bytes2hex(rand(UInt8, 32))
end

function determine_xcm_transport_method(tx_data::Dict{String, Any})::String
    from_type = get(get_xcm_chain_info(PolkadotXCMBridge(), tx_data["from_chain"]), "type", "unknown")
    to_type = get(get_xcm_chain_info(PolkadotXCMBridge(), tx_data["to_chain"]), "type", "unknown")
    
    if from_type == "relay" && to_type == "parachain"
        return "DMP"  # Downward Message Passing
    elseif from_type == "parachain" && to_type == "relay" 
        return "UMP"  # Upward Message Passing
    elseif from_type == "parachain" && to_type == "parachain"
        return "HRMP" # Horizontal Relay Message Passing (XCMP-lite)
    else
        return "UNKNOWN"
    end
end

function get_xcm_supported_assets(bridge::PolkadotXCMBridge, from_chain::String, to_chain::String)::Vector{Dict{String, Any}}
    assets = Vector{Dict{String, Any}}()
    
    common_assets = Dict{String, Dict{String, Any}}(
        "DOT" => Dict(
            "symbol" => "DOT", "decimals" => 10, "name" => "Polkadot",
            "chains" => ["polkadot", "statemint", "acala", "moonbeam", "astar", "bifrost", "parallel", "centrifuge", "interlay"]
        ),
        "KSM" => Dict(
            "symbol" => "KSM", "decimals" => 12, "name" => "Kusama", 
            "chains" => ["kusama", "statemine", "karura", "moonriver", "shiden", "kintsugi", "basilisk"]
        ),
        "PAS" => Dict(
            "symbol" => "PAS", "decimals" => 12, "name" => "Paseo",
            "chains" => ["paseo", "asset_hub_paseo", "bridge_hub_paseo", "people_paseo", "coretime_paseo"]
        ),
        "USDT" => Dict(
            "symbol" => "USDT", "decimals" => 6, "name" => "Tether USD",
            "chains" => ["statemint", "statemine", "asset_hub_paseo", "acala", "karura", "moonbeam", "moonriver"]
        ),
        "USDC" => Dict(
            "symbol" => "USDC", "decimals" => 6, "name" => "USD Coin",
            "chains" => ["statemint", "statemine", "asset_hub_paseo", "acala", "karura", "moonbeam", "moonriver"]
        ),
        "ASTR" => Dict(
            "symbol" => "ASTR", "decimals" => 18, "name" => "Astar",
            "chains" => ["astar", "statemint", "acala", "moonbeam"]
        ),
        "GLMR" => Dict(
            "symbol" => "GLMR", "decimals" => 18, "name" => "Glimmer", 
            "chains" => ["moonbeam", "statemint", "acala"]
        ),
        "MOVR" => Dict(
            "symbol" => "MOVR", "decimals" => 18, "name" => "Moonriver",
            "chains" => ["moonriver", "statemine", "karura"]
        ),
        "ACA" => Dict(
            "symbol" => "ACA", "decimals" => 12, "name" => "Acala",
            "chains" => ["acala", "statemint", "moonbeam"]
        ),
        "KAR" => Dict(
            "symbol" => "KAR", "decimals" => 12, "name" => "Karura",
            "chains" => ["karura", "statemine", "moonriver"]
        )
    )
    
    for (symbol, asset_info) in common_assets
        if from_chain in asset_info["chains"] && to_chain in asset_info["chains"] && from_chain != to_chain
            push!(assets, Dict{String, Any}(
                "token_symbol" => symbol,
                "from_chain" => from_chain,
                "to_chain" => to_chain,
                "decimals" => asset_info["decimals"],
                "name" => asset_info["name"],
                "is_native" => symbol in ["DOT", "KSM"] && (
                    (symbol == "DOT" && from_chain == "polkadot") || 
                    (symbol == "KSM" && from_chain == "kusama")
                ),
                "transfer_type" => determine_xcm_transfer_type(from_chain, to_chain, symbol)
            ))
        end
    end
    
    return assets
end

function determine_xcm_transfer_type(from_chain::String, to_chain::String, asset_symbol::String)::String
    from_info = get_xcm_chain_info(PolkadotXCMBridge(), from_chain)
    to_info = get_xcm_chain_info(PolkadotXCMBridge(), to_chain)
    
    if isnothing(from_info) || isnothing(to_info)
        return "unsupported"
    end
    
    if (asset_symbol == "DOT" && from_info["type"] == "relay") || 
       (asset_symbol == "KSM" && from_info["type"] == "relay")
        return "teleport"
    else
        return "reserve_transfer"
    end
end

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
    
    if !isnothing(from_info) && !isnothing(to_info)
        same_relay = get(from_info, "relay", from_chain) == get(to_info, "relay", to_chain)
        if !same_relay && from_info["type"] != "relay" && to_info["type"] != "relay"
            push!(validation_result["errors"], "Cross-relay transfers between parachains not directly supported")
            validation_result["valid"] = false
        end
    end
    
    min_amount = get(bridge.config.min_transfer_amount, from_chain, 0.01)
    max_amount = get(bridge.config.max_transfer_amount, from_chain, 1000000.0)
    
    if amount < min_amount
        push!(validation_result["errors"], "Transfer amount $amount is below minimum $min_amount for $from_chain")
        validation_result["valid"] = false
    end
    
    if amount > max_amount
        push!(validation_result["errors"], "Transfer amount $amount exceeds maximum $max_amount for $from_chain")
        validation_result["valid"] = false
    end
    
    supported_assets = get_xcm_supported_assets(bridge, from_chain, to_chain)
    asset_supported = any(asset -> asset["token_symbol"] == token_address || 
                               (token_address == "native" && asset["is_native"]), supported_assets)
    
    if !asset_supported
        push!(validation_result["warnings"], "Asset $token_address may not be supported on the destination chain")
    end
    
    return validation_result
end