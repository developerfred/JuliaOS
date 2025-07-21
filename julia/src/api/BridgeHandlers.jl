module BridgeHandlers

using HTTP, JSON3, Dates, Logging, UUIDs
using ..CrossChainBridge, ..Utils

export register_bridge_routes

# =================== SECURITY & AUTHENTICATION ===================

const API_RATE_LIMITS = Dict{String, Vector{DateTime}}()
const MAX_REQUESTS_PER_MINUTE = 60
const MAX_REQUESTS_PER_HOUR = 1000

struct AuthenticationResult
    success::Bool
    user_id::Union{String, Nothing}
    rate_limit_key::String
    error_message::Union{String, Nothing}
end

function authenticate_request(req::HTTP.Request)::AuthenticationResult
    # Extract API key or JWT token from headers
    api_key = HTTP.header(req, "X-API-Key", "")
    auth_header = HTTP.header(req, "Authorization", "")
    client_ip = HTTP.header(req, "X-Real-IP", HTTP.header(req, "X-Forwarded-For", "unknown"))
    
    # For production, implement proper authentication
    # For now, use IP-based rate limiting as fallback
    rate_limit_key = !isempty(api_key) ? "api_key_$(api_key)" : "ip_$(client_ip)"
    
    if !isempty(api_key)
        # Validate API key (implement your validation logic here)
        if validate_api_key(api_key)
            return AuthenticationResult(true, api_key, rate_limit_key, nothing)
        else
            return AuthenticationResult(false, nothing, rate_limit_key, "Invalid API key")
        end
    end
    
    # Allow unauthenticated requests with stricter rate limiting
    return AuthenticationResult(true, nothing, rate_limit_key, nothing)
end

function validate_api_key(api_key::String)::Bool
    # Implement your API key validation logic
    # This is a placeholder - in production, check against database
    valid_keys = get(ENV, "VALID_API_KEYS", "")
    return api_key in split(valid_keys, ",")
end

function check_rate_limit(rate_limit_key::String, max_per_minute::Int = MAX_REQUESTS_PER_MINUTE)::Bool
    current_time = now()
    minute_ago = current_time - Minute(1)
    hour_ago = current_time - Hour(1)
    
    if !haskey(API_RATE_LIMITS, rate_limit_key)
        API_RATE_LIMITS[rate_limit_key] = DateTime[]
    end
    
    # Clean old entries
    filter!(ts -> ts > minute_ago, API_RATE_LIMITS[rate_limit_key])
    
    # Check minute limit
    recent_requests = length(filter(ts -> ts > minute_ago, API_RATE_LIMITS[rate_limit_key]))
    if recent_requests >= max_per_minute
        return false
    end
    
    # Check hourly limit
    hourly_requests = length(filter(ts -> ts > hour_ago, API_RATE_LIMITS[rate_limit_key]))
    if hourly_requests >= MAX_REQUESTS_PER_HOUR
        return false
    end
    
    # Add current request
    push!(API_RATE_LIMITS[rate_limit_key], current_time)
    return true
end

function require_authentication(handler_func::Function)
    return function(req::HTTP.Request, args...)
        # Authenticate request
        auth_result = authenticate_request(req)
        
        # Check rate limit
        if !check_rate_limit(auth_result.rate_limit_key)
            return Utils.error_response("Rate limit exceeded. Please reduce request frequency.", 429,
                                      error_code=Utils.ERROR_CODE_RATE_LIMIT)
        end
        
        # For write operations, require authentication
        if req.method in ["POST", "PUT", "DELETE"] && !auth_result.success
            return Utils.error_response("Authentication required for this operation.", 401,
                                      error_code=Utils.ERROR_CODE_UNAUTHORIZED)
        end
        
        # Call the actual handler
        return handler_func(req, args...)
    end
end

# =================== INPUT VALIDATION ===================

function validate_chain_name(chain::String)::Bool
    valid_chains = [
        "ethereum", "base", "polygon", "arbitrum", "optimism", "avalanche", "bsc",
        "solana", "starknet", "immutable", "linea", "zksync",
        "polkadot", "kusama", "paseo", "statemint", "acala", "moonbeam", "moonriver",
        "astar", "shiden", "bifrost", "parallel", "centrifuge", "interlay"
    ]
    return lowercase(chain) in valid_chains
end

function validate_bridge_name(bridge_name::String)::Bool
    valid_bridges = ["base", "solana", "wormhole", "layerzero", "layerswap", "polkadot_xcm"]
    return lowercase(bridge_name) in valid_bridges
end

function validate_amount_string(amount_str::String)::Union{Float64, Nothing}
    try
        amount = parse(Float64, amount_str)
        if amount <= 0 || amount > CrossChainBridge.MAX_TRANSFER_AMOUNT
            return nothing
        end
        return amount
    catch
        return nothing
    end
end

function validate_address_format(address::String, chain::String)::Bool
    return CrossChainBridge.validate_address(address, chain)
end

function sanitize_input(input::String)::String
    # Remove potentially dangerous characters
    cleaned = replace(input, r"[<>\"'&]" => "")
    return strip(cleaned)
end

# =================== HANDLERS ===================

function list_bridges_handler(req::HTTP.Request)
    try
        bridges = CrossChainBridge.get_supported_bridges()
        
        # Add real-time status information
        enhanced_bridges = []
        for bridge in bridges
            # Check bridge health/status
            status = check_bridge_health(bridge["type"])
            
            enhanced_bridge = merge(bridge, Dict(
                "status" => status["operational"] ? "operational" : "maintenance",
                "last_check" => status["last_check"],
                "current_load" => status["load_percentage"],
                "estimated_processing_time" => status["avg_processing_time"]
            ))
            push!(enhanced_bridges, enhanced_bridge)
        end
        
        return Utils.json_response(Dict(
            "success" => true,
            "bridges" => enhanced_bridges,
            "total_count" => length(enhanced_bridges),
            "timestamp" => now()
        ))
    catch e
        @error "Error listing bridges" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to list bridges: $(sprint(showerror, e))", 500, 
                                  error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function get_bridge_quote_handler(req::HTTP.Request, bridge_name::String)
    # Input validation
    if isempty(bridge_name) || !validate_bridge_name(bridge_name)
        return Utils.error_response("Invalid bridge name parameter.", 400, 
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    body = Utils.parse_request_body(req)
    if isnothing(body) || !isa(body, Dict)
        return Utils.error_response("Request body must be a valid JSON object.", 400, 
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    # Validate required fields
    required_fields = ["from_chain", "to_chain", "from_token", "to_token", "amount"]
    for field in required_fields
        if !haskey(body, field) || isempty(string(body[field]))
            return Utils.error_response("Required field '$field' is missing or empty.", 400, 
                                      error_code=Utils.ERROR_CODE_INVALID_INPUT, 
                                      details=Dict("missing_field" => field))
        end
    end

    # Sanitize inputs
    from_chain = sanitize_input(string(body["from_chain"]))
    to_chain = sanitize_input(string(body["to_chain"]))
    from_token = sanitize_input(string(body["from_token"]))
    to_token = sanitize_input(string(body["to_token"]))
    
    # Validate chains
    if !validate_chain_name(from_chain) || !validate_chain_name(to_chain)
        return Utils.error_response("Invalid chain name(s) provided.", 400,
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end
    
    # Validate and parse amount
    amount = validate_amount_string(string(body["amount"]))
    if isnothing(amount)
        return Utils.error_response("Invalid amount format or value. Must be a positive number within limits.", 400, 
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    try
        bridge = CrossChainBridge.create_bridge(bridge_name)
        if isnothing(bridge)
            return Utils.error_response("Bridge '$bridge_name' not found.", 404, 
                                      error_code=Utils.ERROR_CODE_NOT_FOUND)
        end

        # Enhanced validation
        validation = CrossChainBridge.validate_bridge_transfer(bridge, from_chain, to_chain, amount, from_token)
        if !validation["valid"]
            return Utils.error_response("Transfer validation failed.", 400, 
                                      error_code=Utils.ERROR_CODE_INVALID_INPUT, 
                                      details=validation)
        end

        # Get fee estimate with market conditions
        fee_estimate = CrossChainBridge.estimate_bridge_fees(bridge, from_chain, to_chain, amount)
        
        output_amount = amount - fee_estimate["total_fee"]
        if output_amount <= 0
            return Utils.error_response("Transfer amount too small to cover fees.", 400, 
                                      error_code=Utils.ERROR_CODE_INVALID_INPUT,
                                      details=Dict("required_minimum" => fee_estimate["total_fee"] + 0.01))
        end

        # Create comprehensive quote
        quote = Dict{String, Any}(
            "quote_id" => string(uuid4()),
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
            "slippage_tolerance" => fee_estimate["dynamic_slippage_percent"],
            "security_level" => bridge.config.security_level,
            "confirmations_required" => get_required_confirmations(from_chain),
            "warnings" => get(validation, "warnings", []),
            "created_at" => Dates.now()
        )

        return Utils.json_response(Dict("success" => true, "quote" => quote))
    catch e
        @error "Error getting bridge quote for $bridge_name" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get bridge quote: $(sprint(showerror, e))", 500, 
                                  error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function initiate_transfer_handler(req::HTTP.Request, bridge_name::String)
    if isempty(bridge_name) || !validate_bridge_name(bridge_name)
        return Utils.error_response("Invalid bridge name parameter.", 400, 
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    body = Utils.parse_request_body(req)
    if isnothing(body) || !isa(body, Dict)
        return Utils.error_response("Request body must be a valid JSON object.", 400, 
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    # Validate required fields
    required_fields = ["from_chain", "to_chain", "from_token", "amount", "recipient_address"]
    for field in required_fields
        if !haskey(body, field) || isempty(string(body[field]))
            return Utils.error_response("Required field '$field' is missing or empty.", 400, 
                                      error_code=Utils.ERROR_CODE_INVALID_INPUT, 
                                      details=Dict("missing_field" => field))
        end
    end

    # Sanitize and validate inputs
    from_chain = sanitize_input(string(body["from_chain"]))
    to_chain = sanitize_input(string(body["to_chain"]))
    from_token = sanitize_input(string(body["from_token"]))
    recipient_address = sanitize_input(string(body["recipient_address"]))
    signed_tx_hex = haskey(body, "signed_tx_hex") ? sanitize_input(string(body["signed_tx_hex"])) : nothing
    quote_id = haskey(body, "quote_id") ? sanitize_input(string(body["quote_id"])) : nothing
    
    # Enhanced input validation
    if !validate_chain_name(from_chain) || !validate_chain_name(to_chain)
        return Utils.error_response("Invalid chain name(s) provided.", 400,
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end
    
    if !validate_address_format(recipient_address, to_chain)
        return Utils.error_response("Invalid recipient address format for destination chain.", 400,
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT,
                                  details=Dict("chain" => to_chain, "expected_format" => get_address_format_hint(to_chain)))
    end
    
    amount = validate_amount_string(string(body["amount"]))
    if isnothing(amount)
        return Utils.error_response("Invalid amount format or value.", 400, 
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    # Additional security checks
    if amount > 100000.0  # Large transfer threshold
        large_transfer_validation = validate_large_transfer(body, req)
        if !large_transfer_validation["approved"]
            return Utils.error_response("Large transfer requires additional verification.", 403,
                                      error_code=Utils.ERROR_CODE_LARGE_TRANSFER,
                                      details=large_transfer_validation)
        end
    end

    try
        # Execute the transfer with enhanced error handling
        result = CrossChainBridge.execute_cross_chain_transfer(
            bridge_name, from_chain, to_chain, amount, from_token, recipient_address, signed_tx_hex
        )
        
        if result["success"]
            # Log successful transfer initiation
            @info "Transfer initiated successfully" bridge=bridge_name from=from_chain to=to_chain amount=amount operation_id=result["operation_id"]
            
            # Add additional response metadata
            enhanced_result = merge(result, Dict(
                "quote_id" => quote_id,
                "tracking_url" => generate_tracking_url(result["operation_id"]),
                "support_reference" => generate_support_reference(),
                "estimated_completion_human" => _format_time_duration(get(result, "estimated_time_seconds", 600))
            ))
            
            return Utils.json_response(enhanced_result)
        else
            @warn "Transfer initiation failed" bridge=bridge_name error=result["error"]
            return Utils.error_response(result["error"], 400, 
                                      error_code=Utils.ERROR_CODE_TRANSFER_FAILED, 
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

    # Validate operation ID format
    if !validate_operation_id_format(operation_id)
        return Utils.error_response("Invalid operation ID format.", 400,
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    try
        result = CrossChainBridge.get_transfer_status(bridge_name, operation_id)
        
        if result["success"]
            # Add enhanced status information
            enhanced_result = merge(result, Dict(
                "tracking_url" => generate_tracking_url(operation_id),
                "blockchain_explorer_urls" => generate_explorer_urls(bridge_name, operation_id),
                "support_reference" => extract_support_reference(operation_id),
                "next_update_in_seconds" => calculate_next_status_update(result["status"]),
                "status_history" => get_status_history(operation_id)  # If available
            ))
            
            return Utils.json_response(enhanced_result)
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
    if isempty(bridge_name) || !validate_bridge_name(bridge_name)
        return Utils.error_response("Invalid bridge name parameter.", 400, 
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    query_params = Dict(pairs(HTTP.queryparams(HTTP.URI(req.target))))
    from_chain = get(query_params, "from_chain", nothing)
    to_chain = get(query_params, "to_chain", nothing)

    # Validate chain parameters if provided
    if !isnothing(from_chain) && !validate_chain_name(from_chain)
        return Utils.error_response("Invalid from_chain parameter.", 400,
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end
    
    if !isnothing(to_chain) && !validate_chain_name(to_chain)
        return Utils.error_response("Invalid to_chain parameter.", 400,
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    try
        bridge = CrossChainBridge.create_bridge(bridge_name)
        if isnothing(bridge)
            return Utils.error_response("Bridge '$bridge_name' not found.", 404, 
                                      error_code=Utils.ERROR_CODE_NOT_FOUND)
        end

        assets = _get_bridge_supported_assets(bridge, from_chain, to_chain)
        
        # Add real-time asset information
        enhanced_assets = []
        for asset in assets
            enhanced_asset = merge(asset, Dict(
                "current_liquidity" => get_asset_liquidity(asset["token_symbol"], asset["from_chain"]),
                "price_impact_estimate" => estimate_price_impact(asset["token_symbol"], 1000.0),  # For 1000 units
                "is_recommended" => is_recommended_asset_pair(asset["from_chain"], asset["to_chain"], asset["token_symbol"])
            ))
            push!(enhanced_assets, enhanced_asset)
        end
        
        return Utils.json_response(Dict(
            "success" => true,
            "bridge_name" => bridge.config.name,
            "assets" => enhanced_assets,
            "total_count" => length(enhanced_assets),
            "filters_applied" => Dict(
                "from_chain" => from_chain,
                "to_chain" => to_chain
            ),
            "last_updated" => now()
        ))
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
    status_filter = get(query_params, "status", nothing)
    limit = get(query_params, "limit", nothing)
    offset = get(query_params, "offset", "0")

    # Validate and sanitize parameters
    if !isnothing(bridge_name) && !validate_bridge_name(bridge_name)
        return Utils.error_response("Invalid bridge_name parameter.", 400,
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end
    
    if !isnothing(from_chain) && !validate_chain_name(from_chain)
        return Utils.error_response("Invalid from_chain parameter.", 400,
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end
    
    if !isnothing(to_chain) && !validate_chain_name(to_chain)
        return Utils.error_response("Invalid to_chain parameter.", 400,
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    try
        limit_int = isnothing(limit) ? 50 : parse(Int, limit)
        offset_int = parse(Int, offset)
        
        if limit_int <= 0 || limit_int > 1000
            return Utils.error_response("Limit must be between 1 and 1000.", 400, 
                                      error_code=Utils.ERROR_CODE_INVALID_INPUT)
        end
        
        if offset_int < 0
            return Utils.error_response("Offset must be non-negative.", 400,
                                      error_code=Utils.ERROR_CODE_INVALID_INPUT)
        end
    catch e
        return Utils.error_response("Invalid limit or offset format. Must be numbers.", 400, 
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    try
        transfers = _get_filtered_transfer_history(
            bridge_name, user_address, from_chain, to_chain, 
            token_address, status_filter, limit_int, offset_int
        )
        
        total_count = _get_transfer_history_count(bridge_name, user_address, from_chain, to_chain, token_address, status_filter)
        
        return Utils.json_response(Dict(
            "success" => true,
            "transfers" => transfers,
            "pagination" => Dict(
                "limit" => limit_int,
                "offset" => offset_int,
                "total_count" => total_count,
                "has_more" => offset_int + limit_int < total_count
            ),
            "filters_applied" => filter(p -> !isnothing(p.second), Dict(
                "bridge_name" => bridge_name,
                "user_address" => user_address,
                "from_chain" => from_chain,
                "to_chain" => to_chain,
                "token_address" => token_address,
                "status" => status_filter
            ))
        ))
    catch e
        @error "Error getting transfer history" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get transfer history: $(sprint(showerror, e))", 500, 
                                  error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

# =================== UTILITY FUNCTIONS ===================

function _format_time_duration(seconds::Int)::String
    if seconds < 60
        return "$(seconds) seconds"
    elseif seconds < 3600
        minutes = seconds ÷ 60
        remainder = seconds % 60
        return remainder == 0 ? "$(minutes) minutes" : "$(minutes) minutes $(remainder) seconds"
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
    
    # Enhanced asset data with real market information
    common_tokens = Dict{String, Any}(
        "USDC" => Dict(
            "ethereum" => "0xA0b86a33E6441e39A2ae29A5Deba9C9C0b9DB9",
            "base" => "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
            "polygon" => "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174",
            "arbitrum" => "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
            "optimism" => "0x7F5c764cBc14f9669B88837ca1490cCa17c31607",
            "solana" => "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
            "decimals" => 6,
            "is_stable" => true
        ),
        "USDT" => Dict(
            "ethereum" => "0xdAC17F958D2ee523a2206206994597C13D831ec7",
            "base" => "0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2",
            "polygon" => "0xc2132D05D31c914a87C6611C10748AEb04B58e8F",
            "arbitrum" => "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9",
            "optimism" => "0x94b008aA00579c1307B0EF2c499aD98a8ce58e58",
            "solana" => "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB",
            "decimals" => 6,
            "is_stable" => true
        ),
        "WETH" => Dict(
            "ethereum" => "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
            "base" => "0x4200000000000000000000000000000000000006",
            "polygon" => "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619",
            "arbitrum" => "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1",
            "optimism" => "0x4200000000000000000000000000000000000006",
            "decimals" => 18,
            "is_stable" => false
        ),
        "ETH" => Dict(
            "ethereum" => "native",
            "base" => "native",
            "polygon" => "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619",
            "arbitrum" => "native",
            "optimism" => "native",
            "decimals" => 18,
            "is_stable" => false
        )
    )

    assets = Vector{Dict{String, Any}}()
    supported_chains = bridge.config.supported_chains

    for (token_symbol, token_data) in common_tokens
        for source_chain in supported_chains
            if !isnothing(from_chain) && source_chain != from_chain
                continue
            end
            
            if !haskey(token_data, source_chain)
                continue
            end

            for dest_chain in supported_chains
                if source_chain == dest_chain
                    continue
                end
                
                if !isnothing(to_chain) && dest_chain != to_chain
                    continue
                end

                if haskey(token_data, dest_chain)
                    push!(assets, Dict{String, Any}(
                        "token_symbol" => token_symbol,
                        "from_chain" => source_chain,
                        "to_chain" => dest_chain,
                        "from_chain_address" => token_data[source_chain],
                        "to_chain_address" => token_data[dest_chain],
                        "decimals" => token_data["decimals"],
                        "is_stable" => token_data["is_stable"],
                        "min_transfer_amount" => get(bridge.config.min_transfer_amount, source_chain, 0.01),
                        "max_transfer_amount" => get(bridge.config.max_transfer_amount, source_chain, 1000000.0),
                        "estimated_time_seconds" => get(bridge.config.estimated_time, "$(source_chain)_to_$(dest_chain)", 600)
                    ))
                end
            end
        end
    end

    return assets
end

function _get_filtered_transfer_history(bridge_name::Union{String, Nothing}, 
                                      user_address::Union{String, Nothing},
                                      from_chain::Union{String, Nothing}, 
                                      to_chain::Union{String, Nothing},
                                      token_address::Union{String, Nothing},
                                      status_filter::Union{String, Nothing},
                                      limit::Int, offset::Int = 0)::Vector{Dict{String, Any}}
    # Mock transfer history - in production, this would query a database
    mock_transfers = [
        Dict{String, Any}(
            "operation_id" => "wormhole_$(Int(time()) - 3600)_12345",
            "bridge_name" => "Wormhole",
            "from_chain" => "ethereum",
            "to_chain" => "solana",
            "token_symbol" => "USDC",
            "amount" => 100.0,
            "status" => "completed",
            "created_at" => Dates.now() - Hour(1),
            "completed_at" => Dates.now() - Minute(45),
            "transaction_hashes" => Dict(
                "source" => "0xabc123...",
                "destination" => "def456..."
            ),
            "fees_paid" => 0.5
        ),
        Dict{String, Any}(
            "operation_id" => "layerzero_$(Int(time()) - 1800)_67890",
            "bridge_name" => "LayerZero",
            "from_chain" => "ethereum", 
            "to_chain" => "base",
            "token_symbol" => "ETH",
            "amount" => 0.5,
            "status" => "processing",
            "created_at" => Dates.now() - Minute(30),
            "completed_at" => nothing,
            "transaction_hashes" => Dict(
                "source" => "0xghi789..."
            ),
            "fees_paid" => 0.02
        )
    ]
    
    # Apply filters
    filtered = filter(mock_transfers) do transfer
        (!isnothing(bridge_name) ? lowercase(transfer["bridge_name"]) == lowercase(bridge_name) : true) &&
        (!isnothing(from_chain) ? transfer["from_chain"] == from_chain : true) &&
        (!isnothing(to_chain) ? transfer["to_chain"] == to_chain : true) &&
        (!isnothing(status_filter) ? transfer["status"] == status_filter : true)
    end
    
    # Apply pagination
    start_idx = offset + 1
    end_idx = min(start_idx + limit - 1, length(filtered))
    
    return start_idx <= length(filtered) ? filtered[start_idx:end_idx] : []
end

function _get_transfer_history_count(bridge_name::Union{String, Nothing},
                                   user_address::Union{String, Nothing},
                                   from_chain::Union{String, Nothing},
                                   to_chain::Union{String, Nothing}, 
                                   token_address::Union{String, Nothing},
                                   status_filter::Union{String, Nothing})::Int
    # Mock count - in production, this would be a count query
    return 157  # Example total count
end

# =================== SECURITY AND VALIDATION HELPERS ===================

function check_bridge_health(bridge_type::String)::Dict{String, Any}
    # Mock health check - in production, this would ping the actual bridges
    return Dict{String, Any}(
        "operational" => true,
        "last_check" => Dates.now(),
        "load_percentage" => rand(10:80),
        "avg_processing_time" => rand(300:900)
    )
end

function validate_operation_id_format(operation_id::String)::Bool
    # Expected format: bridge_timestamp_randomnumber
    parts = split(operation_id, "_")
    return length(parts) >= 3 && all(!isempty, parts)
end

function validate_large_transfer(body::Dict, req::HTTP.Request)::Dict{String, Any}
    # Implement additional validation for large transfers
    return Dict{String, Any}(
        "approved" => true,
        "additional_checks" => []
    )
end

function get_address_format_hint(chain::String)::String
    format_hints = Dict(
        "ethereum" => "0x followed by 40 hexadecimal characters",
        "solana" => "32-44 base58 characters",
        "polkadot" => "5 followed by 47 characters (SS58 format)"
    )
    return get(format_hints, chain, "Address format varies by chain")
end

function get_required_confirmations(chain::String)::Int
    confirmations = Dict(
        "ethereum" => 12,
        "base" => 1,
        "polygon" => 10,
        "solana" => 32,
        "arbitrum" => 1,
        "optimism" => 1
    )
    return get(confirmations, chain, 6)
end

function generate_tracking_url(operation_id::String)::String
    base_url = get(ENV, "BRIDGE_TRACKING_URL", "https://bridge.juliaos.com/track")
    return "$base_url/$operation_id"
end

function generate_support_reference()::String
    return "SUP-" * string(rand(UInt32), base=16, pad=8)
end

function extract_support_reference(operation_id::String)::String
    return "SUP-" * string(hash(operation_id), base=16)[1:8]
end

function generate_explorer_urls(bridge_name::String, operation_id::String)::Dict{String, String}
    # Generate blockchain explorer URLs for tracking
    return Dict{String, String}(
        "ethereum" => "https://etherscan.io/tx/...",
        "base" => "https://basescan.org/tx/...",
        "solana" => "https://solscan.io/tx/..."
    )
end

function calculate_next_status_update(status::String)::Int
    status_intervals = Dict(
        "initiated" => 30,
        "pending" => 60, 
        "processing" => 120,
        "validating" => 180,
        "finalizing" => 300,
        "completed" => -1
    )
    return get(status_intervals, status, 60)
end

function get_status_history(operation_id::String)::Vector{Dict{String, Any}}
    # Mock status history - in production, retrieve from database
    return []
end

function get_asset_liquidity(token_symbol::String, chain::String)::String
    # Mock liquidity data - in production, query DEX APIs
    liquidity_levels = ["low", "medium", "high", "very_high"]
    return rand(liquidity_levels)
end

function estimate_price_impact(token_symbol::String, amount::Float64)::Float64
    # Mock price impact estimation - in production, use DEX math
    base_impact = 0.001  # 0.1% base impact
    volume_multiplier = min(2.0, amount / 10000.0)  # Increases with amount
    return base_impact * volume_multiplier
end

function is_recommended_asset_pair(from_chain::String, to_chain::String, token_symbol::String)::Bool
    # Recommend stable pairs and popular routes
    stable_tokens = ["USDC", "USDT", "DAI"]
    popular_routes = [
        ("ethereum", "base"), ("ethereum", "polygon"), 
        ("ethereum", "arbitrum"), ("base", "optimism")
    ]
    
    return token_symbol in stable_tokens || (from_chain, to_chain) in popular_routes
end

# =================== ROUTE REGISTRATION ===================

function register_bridge_routes(router::HTTP.Router; path_prefix::String = "/api/v1")
    @info "Registering bridge API routes with prefix: $path_prefix"
    
    # Apply authentication wrapper to all routes
    list_handler = require_authentication(list_bridges_handler)
    quote_handler = require_authentication(get_bridge_quote_handler) 
    transfer_handler = require_authentication(initiate_transfer_handler)
    status_handler = require_authentication(get_transfer_status_handler)
    assets_handler = require_authentication(get_supported_assets_handler)
    history_handler = require_authentication(get_transfer_history_handler)
    
    # Register routes with enhanced error handling
    try
        HTTP.register!(router, "GET", path_prefix * "/cross_chain/bridges", 
                      req -> safe_handler_wrapper(req, list_handler))
        
        HTTP.register!(router, "POST", path_prefix * "/cross_chain/bridges/{bridge_name}/quote", 
                      req -> safe_handler_wrapper(req, quote_handler, HTTP.getparams(req)["bridge_name"]))
        
        HTTP.register!(router, "POST", path_prefix * "/cross_chain/bridges/{bridge_name}/transfer", 
                      req -> safe_handler_wrapper(req, transfer_handler, HTTP.getparams(req)["bridge_name"]))
        
        HTTP.register!(router, "GET", path_prefix * "/cross_chain/bridges/{bridge_name}/status/{operation_id}", 
                      req -> safe_handler_wrapper(req, status_handler, HTTP.getparams(req)["bridge_name"], 
                                                 HTTP.getparams(req)["operation_id"]))
        
        HTTP.register!(router, "GET", path_prefix * "/cross_chain/bridges/{bridge_name}/assets", 
                      req -> safe_handler_wrapper(req, assets_handler, HTTP.getparams(req)["bridge_name"]))
        
        HTTP.register!(router, "GET", path_prefix * "/cross_chain/transfers/history", 
                      req -> safe_handler_wrapper(req, history_handler))
        
        # Health check endpoint
        HTTP.register!(router, "GET", path_prefix * "/cross_chain/health", 
                      req -> health_check_handler(req))
        
        # Bridge comparison endpoint
        HTTP.register!(router, "POST", path_prefix * "/cross_chain/compare", 
                      req -> safe_handler_wrapper(req, compare_bridges_handler))
        
        @info "Bridge API routes registered successfully"
        
    catch e
        @error "Failed to register bridge routes" exception=(e, catch_backtrace())
        throw(e)
    end
end

function safe_handler_wrapper(req::HTTP.Request, handler::Function, args...)
    try
        return handler(req, args...)
    catch e
        @error "Unhandled error in API handler" exception=(e, catch_backtrace()) method=req.method target=req.target
        return Utils.error_response("Internal server error occurred", 500,
                                  error_code=Utils.ERROR_CODE_SERVER_ERROR,
                                  details=Dict("request_id" => string(uuid4())))
    end
end

# =================== ADDITIONAL API ENDPOINTS ===================

function health_check_handler(req::HTTP.Request)
    try
        # Check all bridges health
        bridge_statuses = Dict{String, Any}()
        
        for (name, _) in CrossChainBridge.BRIDGE_REGISTRY[].bridges
            status = check_bridge_health(name)
            bridge_statuses[name] = status
        end
        
        all_operational = all(status["operational"] for status in values(bridge_statuses))
        
        return Utils.json_response(Dict(
            "status" => all_operational ? "healthy" : "degraded",
            "timestamp" => now(),
            "bridges" => bridge_statuses,
            "version" => "1.0.0",
            "uptime_seconds" => Int(time()) - get(ENV, "START_TIME", Int(time())),
            "total_bridges" => length(bridge_statuses)
        ))
        
    catch e
        @error "Health check failed" exception=(e, catch_backtrace())
        return Utils.error_response("Health check failed", 503,
                                  error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function compare_bridges_handler(req::HTTP.Request)
    body = Utils.parse_request_body(req)
    if isnothing(body) || !isa(body, Dict)
        return Utils.error_response("Request body must be a valid JSON object.", 400,
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    required_fields = ["from_chain", "to_chain", "amount", "token"]
    for field in required_fields
        if !haskey(body, field) || isempty(string(body[field]))
            return Utils.error_response("Required field '$field' is missing.", 400,
                                      error_code=Utils.ERROR_CODE_INVALID_INPUT)
        end
    end

    from_chain = sanitize_input(string(body["from_chain"]))
    to_chain = sanitize_input(string(body["to_chain"]))
    token = sanitize_input(string(body["token"]))
    
    amount = validate_amount_string(string(body["amount"]))
    if isnothing(amount)
        return Utils.error_response("Invalid amount format.", 400,
                                  error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    try
        comparisons = []
        
        # Get quotes from all applicable bridges
        for (bridge_name, bridge) in CrossChainBridge.BRIDGE_REGISTRY[].bridges
            if from_chain in bridge.config.supported_chains && to_chain in bridge.config.supported_chains
                try
                    validation = CrossChainBridge.validate_bridge_transfer(bridge, from_chain, to_chain, amount, token)
                    if validation["valid"]
                        fee_estimate = CrossChainBridge.estimate_bridge_fees(bridge, from_chain, to_chain, amount)
                        
                        comparison = Dict{String, Any}(
                            "bridge_name" => bridge.config.name,
                            "bridge_type" => bridge_name,
                            "total_fee" => fee_estimate["total_fee"],
                            "output_amount" => amount - fee_estimate["total_fee"],
                            "estimated_time_seconds" => fee_estimate["estimated_time_seconds"],
                            "estimated_time_human" => _format_time_duration(fee_estimate["estimated_time_seconds"]),
                            "security_level" => bridge.config.security_level,
                            "slippage_tolerance" => fee_estimate["dynamic_slippage_percent"],
                            "fee_breakdown" => fee_estimate["fee_breakdown"],
                            "warnings" => get(validation, "warnings", [])
                        )
                        
                        push!(comparisons, comparison)
                    end
                catch bridge_error
                    @warn "Failed to get quote from bridge $bridge_name" error=sprint(showerror, bridge_error)
                end
            end
        end
        
        if isempty(comparisons)
            return Utils.error_response("No bridges support the requested route.", 404,
                                      error_code=Utils.ERROR_CODE_NOT_FOUND)
        end
        
        # Sort by different criteria
        by_cost = sort(comparisons, by = c -> c["total_fee"])
        by_speed = sort(comparisons, by = c -> c["estimated_time_seconds"])
        by_output = sort(comparisons, by = c -> -c["output_amount"])  # Descending
        
        recommendations = Dict{String, Any}(
            "cheapest" => by_cost[1],
            "fastest" => by_speed[1], 
            "best_output" => by_output[1]
        )
        
        return Utils.json_response(Dict(
            "success" => true,
            "request_details" => Dict(
                "from_chain" => from_chain,
                "to_chain" => to_chain,
                "amount" => amount,
                "token" => token
            ),
            "comparisons" => comparisons,
            "recommendations" => recommendations,
            "total_options" => length(comparisons),
            "generated_at" => now()
        ))
        
    catch e
        @error "Error comparing bridges" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to compare bridges: $(sprint(showerror, e))", 500,
                                  error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

# =================== WEBSOCKET SUPPORT (Optional) ===================

function setup_websocket_endpoints(router::HTTP.Router; path_prefix::String = "/api/v1")
    # WebSocket endpoint for real-time transfer status updates
    HTTP.register!(router, "GET", path_prefix * "/cross_chain/ws/status/{operation_id}",
                  req -> websocket_status_handler(req, HTTP.getparams(req)["operation_id"]))
end

function websocket_status_handler(req::HTTP.Request, operation_id::String)
    # WebSocket implementation for real-time status updates
    # This would require additional WebSocket libraries
    return Utils.error_response("WebSocket endpoints not yet implemented", 501,
                               error_code=Utils.ERROR_CODE_NOT_IMPLEMENTED)
end

end  # module BridgeHandlers