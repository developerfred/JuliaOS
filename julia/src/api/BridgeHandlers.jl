module BridgeHandlers

using HTTP, JSON3, Dates, Logging
using ..CrossChainBridge, ..Utils

export register_bridge_routes

function list_bridges_handler(req::HTTP.Request)
    try
        bridges = CrossChainBridge.get_supported_bridges()
        return Utils.json_response(Dict("bridges" => bridges))
    catch e
        @error "Error listing bridges" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to list bridges: $(sprint(showerror, e))", 500, 
                                  error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function get_bridge_quote_handler(req::HTTP.Request, bridge_name::String)
    if isempty(bridge_name)
        return Utils.error_response("Bridge name parameter cannot be empty.", 400, 
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    body = Utils.parse_request_body(req)
    if isnothing(body) || !isa(body, Dict)
        return Utils.error_response("Request body must be a JSON object.", 400, 
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    required_fields = ["from_chain", "to_chain", "from_token", "to_token", "amount"]
    for field in required_fields
        if !haskey(body, field) || isempty(string(body[field]))
            return Utils.error_response("Required field '$field' is missing or empty.", 400, 
                                      error_code=Utils.ERROR_CODE_INVALID_INPUT, 
                                      details=Dict("missing_field" => field))
        end
    end

    from_chain = string(body["from_chain"])
    to_chain = string(body["to_chain"])
    from_token = string(body["from_token"])
    to_token = string(body["to_token"])
    
    try
        amount = parse(Float64, string(body["amount"]))
        if amount <= 0
            return Utils.error_response("Amount must be greater than 0.", 400, 
                                      error_code=Utils.ERROR_CODE_INVALID_INPUT)
        end
    catch e
        return Utils.error_response("Invalid amount format. Must be a number.", 400, 
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    try
        result = CrossChainBridge.execute_cross_chain_transfer(
            bridge_name, from_chain, to_chain, amount, from_token, recipient_address, signed_tx_hex
        )
        
        if result["success"]
            return Utils.json_response(result)
        else
            return Utils.error_response(result["error"], 400, 
                                      error_code=Utils.ERROR_CODE_INVALID_INPUT, 
                                      details=get(result, "details", Dict()))
        end
    catch e
        @error "Error initiating transfer for $bridge_name" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to initiate transfer: $(sprint(showerror, e))", 500, 
                                  error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function get_transfer_status_handler(req::HTTP.Request, bridge_name::String, operation_id::String)
    if isempty(bridge_name) || isempty(operation_id)
        return Utils.error_response("Bridge name and operation ID parameters cannot be empty.", 400, 
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    try
        result = CrossChainBridge.get_transfer_status(bridge_name, operation_id)
        
        if result["success"]
            return Utils.json_response(result)
        else
            return Utils.error_response(result["error"], 404, 
                                      error_code=Utils.ERROR_CODE_NOT_FOUND)
        end
    catch e
        @error "Error getting transfer status for $bridge_name, $operation_id" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get transfer status: $(sprint(showerror, e))", 500, 
                                  error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function get_supported_assets_handler(req::HTTP.Request, bridge_name::String)
    if isempty(bridge_name)
        return Utils.error_response("Bridge name parameter cannot be empty.", 400, 
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    query_params = Dict(pairs(HTTP.queryparams(HTTP.URI(req.target))))
    from_chain = get(query_params, "from_chain", nothing)
    to_chain = get(query_params, "to_chain", nothing)

    try
        bridge = CrossChainBridge.create_bridge(bridge_name)
        if isnothing(bridge)
            return Utils.error_response("Bridge '$bridge_name' not found.", 404, 
                                      error_code=Utils.ERROR_CODE_NOT_FOUND)
        end

        assets = _get_bridge_supported_assets(bridge, from_chain, to_chain)
        return Utils.json_response(Dict("assets" => assets))
    catch e
        @error "Error getting supported assets for $bridge_name" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get supported assets: $(sprint(showerror, e))", 500, 
                                  error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function get_transfer_history_handler(req::HTTP.Request)
    query_params = Dict(pairs(HTTP.queryparams(HTTP.URI(req.target))))
    
    bridge_name = get(query_params, "bridge_name", nothing)
    user_address = get(query_params, "user_address", nothing)
    from_chain = get(query_params, "from_chain", nothing)
    to_chain = get(query_params, "to_chain", nothing)
    token_address = get(query_params, "token_address", nothing)
    limit = get(query_params, "limit", nothing)

    try
        limit_int = isnothing(limit) ? 50 : parse(Int, limit)
        if limit_int <= 0 || limit_int > 1000
            return Utils.error_response("Limit must be between 1 and 1000.", 400, 
                                      error_code=Utils.ERROR_CODE_INVALID_INPUT)
        end
    catch e
        return Utils.error_response("Invalid limit format. Must be a number.", 400, 
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    try
        transfers = _get_filtered_transfer_history(bridge_name, user_address, from_chain, 
                                                 to_chain, token_address, limit_int)
        return Utils.json_response(Dict("transfers" => transfers))
    catch e
        @error "Error getting transfer history" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get transfer history: $(sprint(showerror, e))", 500, 
                                  error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function _format_time_duration(seconds::Int)::String
    if seconds < 60
        return "$(seconds) seconds"
    elseif seconds < 3600
        minutes = seconds ÷ 60
        return "$(minutes) minutes"
    else
        hours = seconds ÷ 3600
        minutes = (seconds % 3600) ÷ 60
        if minutes == 0
            return "$(hours) hours"
        else
            return "$(hours) hours $(minutes) minutes"
        end
    end
end

function _get_bridge_supported_assets(bridge::CrossChainBridge.AbstractBridge, 
                                    from_chain::Union{String, Nothing}, 
                                    to_chain::Union{String, Nothing})::Vector{Dict{String, Any}}
    
    common_tokens = Dict{String, Any}(
        "USDC" => Dict(
            "ethereum" => "0xA0b86a33E6441e39A2ae29A5Deba9C9C0b9DB9",
            "base" => "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
            "polygon" => "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174",
            "arbitrum" => "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
            "optimism" => "0x7F5c764cBc14f9669B88837ca1490cCa17c31607",
            "solana" => "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
        ),
        "USDT" => Dict(
            "ethereum" => "0xdAC17F958D2ee523a2206206994597C13D831ec7",
            "base" => "0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2",
            "polygon" => "0xc2132D05D31c914a87C6611C10748AEb04B58e8F",
            "arbitrum" => "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9",
            "optimism" => "0x94b008aA00579c1307B0EF2c499aD98a8ce58e58",
            "solana" => "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"
        ),
        "WETH" => Dict(
            "ethereum" => "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
            "base" => "0x4200000000000000000000000000000000000006",
            "polygon" => "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619",
            "arbitrum" => "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1",
            "optimism" => "0x4200000000000000000000000000000000000006"
        )
    )

    assets = Vector{Dict{String, Any}}()
    supported_chains = bridge.config.supported_chains

    for (token_symbol, addresses) in common_tokens
        for source_chain in supported_chains
            if !isnothing(from_chain) && source_chain != from_chain
                continue
            end
            
            if !haskey(addresses, source_chain)
                continue
            end

            for dest_chain in supported_chains
                if source_chain == dest_chain
                    continue
                end
                
                if !isnothing(to_chain) && dest_chain != to_chain
                    continue
                end

                if haskey(addresses, dest_chain)
                    push!(assets, Dict{String, Any}(
                        "token_symbol" => token_symbol,
                        "from_chain" => source_chain,
                        "to_chain" => dest_chain,
                        "from_chain_address" => addresses[source_chain],
                        "to_chain_address" => addresses[dest_chain],
                        "decimals" => token_symbol in ["USDC", "USDT"] ? 6 : 18,
                        "is_native" => false
                    ))
                end
            end
        end
    end

    for source_chain in supported_chains
        if !isnothing(from_chain) && source_chain != from_chain
            continue
        end

        for dest_chain in supported_chains
            if source_chain == dest_chain
                continue
            end
            
            if !isnothing(to_chain) && dest_chain != to_chain
                continue
            end

            native_symbol = if source_chain == "solana" "SOL" else "ETH" end
            push!(assets, Dict{String, Any}(
                "token_symbol" => native_symbol,
                "from_chain" => source_chain,
                "to_chain" => dest_chain,
                "from_chain_address" => "native",
                "to_chain_address" => "native",
                "decimals" => source_chain == "solana" ? 9 : 18,
                "is_native" => true
            ))
        end
    end

    return assets
end

function _get_filtered_transfer_history(bridge_name::Union{String, Nothing}, 
                                      user_address::Union{String, Nothing},
                                      from_chain::Union{String, Nothing}, 
                                      to_chain::Union{String, Nothing},
                                      token_address::Union{String, Nothing}, 
                                      limit::Int)::Vector{Dict{String, Any}}
    
    sample_transfers = [
        Dict{String, Any}(
            "operation_id" => "wormhole_1704067200_1234",
            "bridge_name" => "Wormhole",
            "from_chain" => "ethereum",
            "to_chain" => "solana",
            "token_symbol" => "USDC",
            "amount" => 1000.0,
            "recipient_address" => "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU",
            "status" => "completed",
            "created_at" => "2024-01-01T00:00:00Z",
            "completed_at" => "2024-01-01T00:15:00Z",
            "transaction_hash" => "0xabc123...",
            "destination_hash" => "5KJp9nF2..."
        ),
        Dict{String, Any}(
            "operation_id" => "layerzero_1704153600_5678",
            "bridge_name" => "LayerZero",
            "from_chain" => "base",
            "to_chain" => "ethereum",
            "token_symbol" => "ETH",
            "amount" => 0.5,
            "recipient_address" => "0x742d35Cc6635C0532925a3b8D6Ac6d7a9a93c55a",
            "status" => "processing",
            "created_at" => "2024-01-02T00:00:00Z",
            "transaction_hash" => "0xdef456...",
            "destination_hash" => nothing
        )
    ]

    filtered_transfers = filter(sample_transfers) do transfer
        if !isnothing(bridge_name) && transfer["bridge_name"] != bridge_name
            return false
        end
        if !isnothing(from_chain) && transfer["from_chain"] != from_chain
            return false
        end
        if !isnothing(to_chain) && transfer["to_chain"] != to_chain
            return false
        end
        if !isnothing(user_address) && transfer["recipient_address"] != user_address
            return false
        end
        return true
    end

    return filtered_transfers[1:min(length(filtered_transfers), limit)]
end

function register_bridge_routes(router::HTTP.Router; path_prefix::String="/api/v1")
    HTTP.register!(router, "GET", path_prefix * "/cross_chain/bridges", 
                  req -> list_bridges_handler(req))
    
    HTTP.register!(router, "POST", path_prefix * "/cross_chain/bridges/{bridge_name}/quote", 
                  req -> get_bridge_quote_handler(req, HTTP.getparams(req)["bridge_name"]))
    
    HTTP.register!(router, "POST", path_prefix * "/cross_chain/bridges/{bridge_name}/transfer", 
                  req -> initiate_transfer_handler(req, HTTP.getparams(req)["bridge_name"]))
    
    HTTP.register!(router, "GET", path_prefix * "/cross_chain/bridges/{bridge_name}/status/{operation_id}", 
                  req -> get_transfer_status_handler(req, HTTP.getparams(req)["bridge_name"], 
                                                   HTTP.getparams(req)["operation_id"]))
    
    HTTP.register!(router, "GET", path_prefix * "/cross_chain/bridges/{bridge_name}/assets", 
                  req -> get_supported_assets_handler(req, HTTP.getparams(req)["bridge_name"]))
    
    HTTP.register!(router, "GET", path_prefix * "/cross_chain/transfers/history", 
                  req -> get_transfer_history_handler(req))
    
    @info "Bridge API routes registered successfully"
end

end
        return Utils.error_response("Invalid amount format. Must be a number.", 400, 
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    try
        bridge = CrossChainBridge.create_bridge(bridge_name)
        if isnothing(bridge)
            return Utils.error_response("Bridge '$bridge_name' not found.", 404, 
                                      error_code=Utils.ERROR_CODE_NOT_FOUND)
        end

        validation = CrossChainBridge.validate_bridge_transfer(bridge, from_chain, to_chain, amount, from_token)
        if !validation["valid"]
            return Utils.error_response("Transfer validation failed.", 400, 
                                      error_code=Utils.ERROR_CODE_INVALID_INPUT, 
                                      details=validation)
        end

        fee_estimate = CrossChainBridge.estimate_bridge_fees(bridge, from_chain, to_chain, amount)
        
        output_amount = amount - fee_estimate["total_fee"]
        if output_amount <= 0
            return Utils.error_response("Transfer amount too small to cover fees.", 400, 
                                      error_code=Utils.ERROR_CODE_INVALID_INPUT)
        end

        quote = Dict{String, Any}(
            "bridge" => bridge.config.name,
            "from_chain" => from_chain,
            "to_chain" => to_chain,
            "from_token" => from_token,
            "to_token" => to_token,
            "input_amount" => amount,
            "output_amount" => output_amount,
            "fee_breakdown" => fee_estimate,
            "estimated_time_seconds" => fee_estimate["estimated_time_seconds"],
            "estimated_time_human" => _format_time_duration(fee_estimate["estimated_time_seconds"]),
            "quote_valid_until" => Dates.now() + Dates.Minute(5),
            "warnings" => get(validation, "warnings", [])
        )

        return Utils.json_response(quote)
    catch e
        @error "Error getting bridge quote for $bridge_name" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get bridge quote: $(sprint(showerror, e))", 500, 
                                  error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function initiate_transfer_handler(req::HTTP.Request, bridge_name::String)
    if isempty(bridge_name)
        return Utils.error_response("Bridge name parameter cannot be empty.", 400, 
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    body = Utils.parse_request_body(req)
    if isnothing(body) || !isa(body, Dict)
        return Utils.error_response("Request body must be a JSON object.", 400, 
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    required_fields = ["from_chain", "to_chain", "from_token", "amount", "recipient_address"]
    for field in required_fields
        if !haskey(body, field) || isempty(string(body[field]))
            return Utils.error_response("Required field '$field' is missing or empty.", 400, 
                                      error_code=Utils.ERROR_CODE_INVALID_INPUT, 
                                      details=Dict("missing_field" => field))
        end
    end

    from_chain = string(body["from_chain"])
    to_chain = string(body["to_chain"])
    from_token = string(body["from_token"])
    recipient_address = string(body["recipient_address"])
    signed_tx_hex = get(body, "signed_tx_hex", nothing)
    
    try
        amount = parse(Float64, string(body["amount"]))
        if amount <= 0
            return Utils.error_response("Amount must be greater than 0.", 400, 
                                      error_code=Utils.ERROR_CODE_INVALID_INPUT)
        end
    catch e