module fa_factory::fa_factory {
    use std::signer;
    use std::option;
    use std::error;
    use std::string;
    use aptos_framework::object::{Self, ExtendRef};
    use aptos_framework::fungible_asset::{Self, Metadata, MintRef, BurnRef, TransferRef};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use aptos_framework::event;

    const ENOT_OWNER: u64 = 100;
    const EINSUFFICIENT_FUNDS: u64 = 101;
    const EINSUFFICIENT_TOKEN_BALANCE: u64 = 102;
    const EINVALID_AMOUNT: u64 = 103;
    const EINSUFFICIENT_CONTRACT_TOKENS: u64 = 104;

    struct ManagedFA has key {
        symbol: vector<u8>,
        name: vector<u8>,
        decimals: u8,
        icon_url: vector<u8>,
        project_url: vector<u8>,
        description: vector<u8>,
        mint: MintRef,
        burn: BurnRef,
        transfer: TransferRef,
        extend: ExtendRef,
        creator: address,        // Địa chỉ người tạo coin
        reserve: u64,           // APT reserve trong pool
        total_supply: u64,      // Total supply (cố định)
        circulating_supply: u64, // Số token đang lưu hành (bán ra ngoài)
        k: u64,                 // Constant cho bonding curve
        fee_rate: u64,          // Fee rate (basis points, e.g., 100 = 1%)
        // RWA specific fields
        asset_type: vector<u8>, // Loại tài sản (real estate, commodities, stocks, etc.)
        backing_ratio: u64,     // Tỷ lệ backing bằng tài sản thực (basis points)
        withdrawal_limit: u64,  // Giới hạn rút APT (basis points của reserve)
        last_withdrawal: u64,   // Timestamp lần rút cuối
        withdrawal_cooldown: u64, // Cooldown period giữa các lần rút
        is_emergency: bool,     // Emergency mode
        // Bonding curve progress
        graduation_threshold: u64, // Ngưỡng để "graduate" khỏi bonding curve
        graduation_target: u64,   // Target market cap để graduate
        is_graduated: bool,       // Đã graduate chưa
        oracle_price: u64,        // Giá từ oracle (sau khi graduate)
        last_oracle_update: u64,  // Timestamp update oracle cuối
    }

    // Event structures
    #[event]
    struct TokenCreated has drop, store {
        symbol: vector<u8>,
        name: vector<u8>,
        decimals: u8,
        icon_url: vector<u8>,
        project_url: vector<u8>,
        description: vector<u8>,
        creator: address,
        total_supply: u64,
        k: u64,
        object_address: address,
        asset_type: vector<u8>,
        backing_ratio: u64,
    }

    #[event]
    struct TokenBought has drop, store {
        buyer: address,
        symbol: vector<u8>,
        apt_paid: u64,
        tokens_received: u64,
        new_circulating_supply: u64,
        new_reserve: u64,
    }

    #[event]
    struct TokenSold has drop, store {
        seller: address,
        symbol: vector<u8>,
        tokens_sold: u64,
        apt_received: u64,
        new_circulating_supply: u64,
        new_reserve: u64,
    }

    #[event]
    struct ReserveWithdrawn has drop, store {
        creator: address,
        symbol: vector<u8>,
        amount_withdrawn: u64,
        remaining_reserve: u64,
        timestamp: u64,
    }

    #[event]
    struct EmergencyWithdrawn has drop, store {
        creator: address,
        symbol: vector<u8>,
        amount_withdrawn: u64,
        reason: vector<u8>,
        timestamp: u64,
    }

    #[event]
    struct OraclePriceUpdated has drop, store {
        creator: address,
        symbol: vector<u8>,
        new_price: u64,
        timestamp: u64,
    }

    #[event]
    struct TokenGraduated has drop, store {
        creator: address,
        symbol: vector<u8>,
        final_circulating_supply: u64,
        final_reserve: u64,
        timestamp: u64,
    }

    public entry fun create_token(
        creator: &signer,
        symbol: vector<u8>,
        name: vector<u8>,
        icon: vector<u8>,
        project_url: vector<u8>,
        description: vector<u8>,
        decimals: u8,
        total_supply: u64,      // Fixed total supply
        k: u64,
        fee_rate: u64,
        asset_type: vector<u8>,
        backing_ratio: u64,
        withdrawal_limit: u64,
        withdrawal_cooldown: u64,
        graduation_threshold: u64,
        graduation_target: u64
    ) {
        let creator_addr = signer::address_of(creator);
        
        // Tạo object với địa chỉ deterministic
        let constructor = &object::create_named_object(creator, symbol);
        let object_signer = object::generate_signer(constructor);
        let object_addr = signer::address_of(&object_signer);

        // Tạo fungible asset
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            constructor,
            option::none(),
            string::utf8(name),
            string::utf8(symbol),
            decimals,
            string::utf8(icon),
            string::utf8(project_url)
        );

        let mint = fungible_asset::generate_mint_ref(constructor);
        let burn = fungible_asset::generate_burn_ref(constructor);
        let transfer = fungible_asset::generate_transfer_ref(constructor);
        let extend = object::generate_extend_ref(constructor);

        // Register contract để nhận APT
        coin::register<AptosCoin>(&object_signer);
        
        // Mint toàn bộ supply cho contract (không phải creator)
        let asset = object::object_from_constructor_ref<Metadata>(constructor);
        let contract_store = primary_fungible_store::ensure_primary_store_exists(
            object_addr, 
            asset
        );
        let total_tokens = fungible_asset::mint(&mint, total_supply);
        fungible_asset::deposit_with_ref(&transfer, contract_store, total_tokens);
        
        // Lưu thông tin contract
        move_to(&object_signer, ManagedFA {
            symbol,
            name,
            decimals,
            icon_url: icon,
            project_url,
            description,
            mint,
            burn,
            transfer,
            extend,
            creator: creator_addr,
            reserve: 0,
            total_supply,
            circulating_supply: 0,  // Chưa có token nào được bán ra
            k,
            fee_rate,
            asset_type,
            backing_ratio,
            withdrawal_limit,
            last_withdrawal: 0,
            withdrawal_cooldown,
            is_emergency: false,
            graduation_threshold,
            graduation_target,
            is_graduated: false,
            oracle_price: 0,
            last_oracle_update: 0,
        });

        // Emit event
        event::emit(TokenCreated {
            symbol,
            name,
            decimals,
            icon_url: icon,
            project_url,
            description,
            creator: creator_addr,
            total_supply,
            k,
            object_address: object_addr,
            asset_type,
            backing_ratio,
        });
    }

    public fun get_metadata(creator: address, symbol: vector<u8>): object::Object<Metadata> {
        let addr = object::create_object_address(&creator, symbol);
        object::address_to_object<Metadata>(addr)
    }

    // Helper function để get object address
    #[view]
    public fun get_object_address(creator: address, symbol: vector<u8>): address {
        object::create_object_address(&creator, symbol)
    }

    // Buy tokens with APT - mua token từ contract pool
    public entry fun buy_tokens(
        buyer: &signer,
        creator: address,
        symbol: vector<u8>,
        apt_amount: u64
    ) acquires ManagedFA {
        assert!(apt_amount > 0, error::invalid_argument(EINVALID_AMOUNT));
        
        let asset = get_metadata(creator, symbol);
        let object_addr = object::object_address(&asset);
        let fa = borrow_global_mut<ManagedFA>(object_addr);
        let buyer_addr = signer::address_of(buyer);

        // Check buyer has enough APT
        assert!(coin::balance<AptosCoin>(buyer_addr) >= apt_amount, 
                error::invalid_argument(EINSUFFICIENT_FUNDS));

        // Calculate fee and net amount
        let fee = (apt_amount * fa.fee_rate) / 10000;
        let net_amount = apt_amount - fee;

        // Calculate tokens to receive based on bonding curve or oracle price
        let token_amount = if (fa.is_graduated) {
            // Đã graduate: dùng oracle price
            assert!(fa.oracle_price > 0, error::invalid_state(108)); // ENO_ORACLE_PRICE
            net_amount / fa.oracle_price
        } else {
            // Chưa graduate: dùng bonding curve
            compute_buy_amount(fa.k, fa.circulating_supply, net_amount)
        };
        
        // Check contract has enough tokens
        let contract_store = primary_fungible_store::primary_store(object_addr, asset);
        let contract_balance = fungible_asset::balance(contract_store);
        assert!(contract_balance >= token_amount, 
                error::invalid_argument(EINSUFFICIENT_CONTRACT_TOKENS));

        // Update state BEFORE transfers
        fa.reserve = fa.reserve + net_amount;
        fa.circulating_supply = fa.circulating_supply + token_amount;

        // Check graduation condition
        check_graduation(fa);

        // Transfer APT from buyer to contract
        coin::transfer<AptosCoin>(buyer, object_addr, apt_amount);

        // Transfer tokens from contract to buyer
        let buyer_store = primary_fungible_store::ensure_primary_store_exists(buyer_addr, asset);
        let tokens_to_transfer = fungible_asset::withdraw_with_ref(&fa.transfer, contract_store, token_amount);
        fungible_asset::deposit_with_ref(&fa.transfer, buyer_store, tokens_to_transfer);

        // Emit event
        event::emit(TokenBought {
            buyer: buyer_addr,
            symbol: fa.symbol,
            apt_paid: apt_amount,
            tokens_received: token_amount,
            new_circulating_supply: fa.circulating_supply,
            new_reserve: fa.reserve,
        });
    }

    // Sell tokens for APT - trả token về contract pool và nhận APT
    public entry fun sell_tokens(
        seller: &signer,
        creator: address,
        symbol: vector<u8>,
        token_amount: u64
    ) acquires ManagedFA {
        assert!(token_amount > 0, error::invalid_argument(EINVALID_AMOUNT));
        
        let asset = get_metadata(creator, symbol);
        let object_addr = object::object_address(&asset);
        let fa = borrow_global_mut<ManagedFA>(object_addr);
        let seller_addr = signer::address_of(seller);

        // Check seller has enough tokens
        let seller_store = primary_fungible_store::primary_store(seller_addr, asset);
        assert!(fungible_asset::balance(seller_store) >= token_amount,
                error::invalid_argument(EINSUFFICIENT_TOKEN_BALANCE));

        // Calculate APT to return based on bonding curve or oracle price
        let apt_refund = if (fa.is_graduated) {
            // Đã graduate: dùng oracle price
            assert!(fa.oracle_price > 0, error::invalid_state(108)); // ENO_ORACLE_PRICE
            token_amount * fa.oracle_price
        } else {
            // Chưa graduate: dùng bonding curve
            compute_sell_amount(fa.k, fa.circulating_supply, token_amount)
        };
        
        let fee = (apt_refund * fa.fee_rate) / 10000;
        let net_refund = apt_refund - fee;
        
        // Check contract has enough APT
        assert!(fa.reserve >= apt_refund, error::invalid_argument(EINSUFFICIENT_FUNDS));

        // Update state BEFORE transfers
        fa.reserve = fa.reserve - apt_refund;
        fa.circulating_supply = fa.circulating_supply - token_amount;

        // Transfer tokens from seller back to contract
        let contract_store = primary_fungible_store::primary_store(object_addr, asset);
        let tokens_to_return = fungible_asset::withdraw_with_ref(&fa.transfer, seller_store, token_amount);
        fungible_asset::deposit_with_ref(&fa.transfer, contract_store, tokens_to_return);

        // Transfer APT from contract to seller
        let contract_signer = object::generate_signer_for_extending(&fa.extend);
        coin::transfer<AptosCoin>(&contract_signer, seller_addr, net_refund);

        // Emit event
        event::emit(TokenSold {
            seller: seller_addr,
            symbol: fa.symbol,
            tokens_sold: token_amount,
            apt_received: net_refund,
            new_circulating_supply: fa.circulating_supply,
            new_reserve: fa.reserve,
        });
    }

    // Get current price for buying tokens
    #[view]
    public fun get_buy_price(creator: address, symbol: vector<u8>, apt_amount: u64): u64 acquires ManagedFA {
        let asset = get_metadata(creator, symbol);
        let fa = borrow_global<ManagedFA>(object::object_address(&asset));
        
        let fee = (apt_amount * fa.fee_rate) / 10000;
        let net_amount = apt_amount - fee;
        
        if (fa.is_graduated) {
            assert!(fa.oracle_price > 0, error::invalid_state(108));
            net_amount / fa.oracle_price
        } else {
            compute_buy_amount(fa.k, fa.circulating_supply, net_amount)
        }
    }

    // Get current price for selling tokens
    #[view]
    public fun get_sell_price(creator: address, symbol: vector<u8>, token_amount: u64): u64 acquires ManagedFA {
        let asset = get_metadata(creator, symbol);
        let fa = borrow_global<ManagedFA>(object::object_address(&asset));
        
        let apt_refund = if (fa.is_graduated) {
            assert!(fa.oracle_price > 0, error::invalid_state(108));
            token_amount * fa.oracle_price
        } else {
            compute_sell_amount(fa.k, fa.circulating_supply, token_amount)
        };
        
        let fee = (apt_refund * fa.fee_rate) / 10000;
        apt_refund - fee
    }

    // Get token info
    #[view]
    public fun get_token_info(creator: address, symbol: vector<u8>): (address, u64, u64, u64, u64, u64, vector<u8>, u64, bool, bool, u64, u64) acquires ManagedFA {
        let asset = get_metadata(creator, symbol);
        let fa = borrow_global<ManagedFA>(object::object_address(&asset));
        (fa.creator, fa.reserve, fa.total_supply, fa.circulating_supply, fa.k, fa.fee_rate, fa.asset_type, fa.backing_ratio, fa.is_emergency, fa.is_graduated, fa.graduation_threshold, fa.graduation_target)
    }

    // Get full token info including all metadata and current state
    #[view]
    public fun get_full_token_info(creator: address, symbol: vector<u8>): (
        // Basic token info
        vector<u8>,  // symbol
        vector<u8>,  // name
        u8,          // decimals
        vector<u8>,  // icon_url
        vector<u8>,  // project_url
        vector<u8>,  // description
        address,     // creator
        u64,         // total_supply
        u64,         // circulating_supply
        // Bonding curve params
        u64,         // k
        u64,         // fee_rate
        // RWA params
        vector<u8>,  // asset_type
        u64,         // backing_ratio
        u64,         // withdrawal_limit
        u64,         // withdrawal_cooldown
        // Graduation params
        u64,         // graduation_threshold
        u64,         // graduation_target
        bool,        // is_graduated
        u64,         // oracle_price
        // Pool state
        u64,         // reserve (APT)
        u64,         // current_price_apt
        u64,         // current_price_usd (using oracle)
        u64,         // liquidity (APT)
        u64,         // market_cap (APT)
        vector<u8>   // sale_status
    ) acquires ManagedFA {
        let asset = get_metadata(creator, symbol);
        let fa = borrow_global<ManagedFA>(object::object_address(&asset));
        
        // Calculate current price in APT
        let current_price_apt = if (fa.is_graduated) {
            fa.oracle_price
        } else {
            let price_multiplier = fa.k + (fa.circulating_supply / 1000000);
            if (price_multiplier == 0) { 1 } else { price_multiplier }
        };

        // Calculate market cap in APT
        let market_cap = fa.circulating_supply * current_price_apt;
        
        // Determine sale status
        let sale_status = if (fa.is_emergency) {
            b"Emergency"
        } else if (fa.is_graduated) {
            b"Graduated"
        } else {
            b"Bonding"
        };

        (
            // Basic token info
            fa.symbol,
            fa.name,
            fa.decimals,
            fa.icon_url,
            fa.project_url,
            fa.description,
            fa.creator,
            fa.total_supply,
            fa.circulating_supply,
            // Bonding curve params
            fa.k,
            fa.fee_rate,
            // RWA params
            fa.asset_type,
            fa.backing_ratio,
            fa.withdrawal_limit,
            fa.withdrawal_cooldown,
            // Graduation params
            fa.graduation_threshold,
            fa.graduation_target,
            fa.is_graduated,
            fa.oracle_price,
            // Pool state
            fa.reserve,
            current_price_apt,
            current_price_apt,  // USD price (same as APT for now, need oracle)
            fa.reserve,         // Liquidity = reserve
            market_cap,
            sale_status
        )
    }

    // Get graduation progress
    #[view]
    public fun get_graduation_progress(creator: address, symbol: vector<u8>): (u64, u64, u64, bool) acquires ManagedFA {
        let asset = get_metadata(creator, symbol);
        let fa = borrow_global<ManagedFA>(object::object_address(&asset));
        let current_progress = if (fa.graduation_target > 0) {
            (fa.circulating_supply * 10000) / fa.graduation_target
        } else {
            0
        };
        (fa.circulating_supply, fa.graduation_target, current_progress, fa.is_graduated)
    }

    // Update oracle price (chỉ sau khi graduate)
    public entry fun update_oracle_price(
        admin: &signer,
        creator: address,
        symbol: vector<u8>,
        new_price: u64
    ) acquires ManagedFA {
        let asset = get_metadata(creator, symbol);
        let fa = borrow_global_mut<ManagedFA>(object::object_address(&asset));
        
        assert!(signer::address_of(admin) == fa.creator, 
                error::permission_denied(ENOT_OWNER));
        assert!(fa.is_graduated, error::invalid_state(109)); // ENOT_GRADUATED
        assert!(new_price > 0, error::invalid_argument(EINVALID_AMOUNT));
        
        fa.oracle_price = new_price;
        fa.last_oracle_update = timestamp::now_seconds();
        
        // Emit event
        event::emit(OraclePriceUpdated {
            creator: fa.creator,
            symbol: fa.symbol,
            new_price,
            timestamp: fa.last_oracle_update,
        });
    }

    // Check graduation condition
    fun check_graduation(fa: &mut ManagedFA) {
        if (!fa.is_graduated && fa.circulating_supply >= fa.graduation_threshold) {
            fa.is_graduated = true;
            
            // Emit graduation event
            event::emit(TokenGraduated {
                creator: fa.creator,
                symbol: fa.symbol,
                final_circulating_supply: fa.circulating_supply,
                final_reserve: fa.reserve,
                timestamp: timestamp::now_seconds(),
            });
        }
    }

    // Get withdrawal info
    #[view]
    public fun get_withdrawal_info(creator: address, symbol: vector<u8>): (u64, u64, u64, u64) acquires ManagedFA {
        let asset = get_metadata(creator, symbol);
        let fa = borrow_global<ManagedFA>(object::object_address(&asset));
        let now = aptos_framework::timestamp::now_seconds();
        let next_withdrawal = fa.last_withdrawal + fa.withdrawal_cooldown;
        let max_withdrawal = (fa.reserve * fa.withdrawal_limit) / 10000;
        (fa.withdrawal_limit, next_withdrawal, max_withdrawal, fa.last_withdrawal)
    }

    // Admin function to withdraw fees
    public entry fun withdraw_fees(
        admin: &signer,
        creator: address,
        symbol: vector<u8>,
        amount: u64
    ) acquires ManagedFA {
        let asset = get_metadata(creator, symbol);
        let object_addr = object::object_address(&asset);
        let fa = borrow_global_mut<ManagedFA>(object_addr);
        
        // Chỉ creator mới có thể withdraw fees
        assert!(signer::address_of(admin) == fa.creator, 
                error::permission_denied(ENOT_OWNER));
        
        let contract_balance = coin::balance<AptosCoin>(object_addr);
        let available_fees = contract_balance - fa.reserve;
        assert!(amount <= available_fees, error::invalid_argument(EINSUFFICIENT_FUNDS));

        let contract_signer = object::generate_signer_for_extending(&fa.extend);
        coin::transfer<AptosCoin>(&contract_signer, signer::address_of(admin), amount);
    }

    // Check if token exists
    #[view]
    public fun token_exists(creator: address, symbol: vector<u8>): bool {
        let addr = object::create_object_address(&creator, symbol);
        exists<ManagedFA>(addr)
    }

    // RWA: Withdraw reserve theo giới hạn
    public entry fun withdraw_reserve(
        admin: &signer,
        creator: address,
        symbol: vector<u8>,
        amount: u64
    ) acquires ManagedFA {
        let asset = get_metadata(creator, symbol);
        let object_addr = object::object_address(&asset);
        let fa = borrow_global_mut<ManagedFA>(object_addr);
        
        assert!(signer::address_of(admin) == fa.creator, 
                error::permission_denied(ENOT_OWNER));
        
        // Check cooldown
        let now = aptos_framework::timestamp::now_seconds();
        assert!(now >= fa.last_withdrawal + fa.withdrawal_cooldown,
                error::invalid_state(105)); // ECOOLDOWN_NOT_EXPIRED
        
        // Check withdrawal limit
        let max_withdrawal = (fa.reserve * fa.withdrawal_limit) / 10000;
        assert!(amount <= max_withdrawal, 
                error::invalid_argument(106)); // EEXCEEDS_WITHDRAWAL_LIMIT
        
        // Ensure minimum backing ratio
        let remaining_reserve = fa.reserve - amount;
        let required_backing = (fa.circulating_supply * fa.backing_ratio) / 10000;
        assert!(remaining_reserve >= required_backing,
                error::invalid_argument(107)); // EINSUFFICIENT_BACKING
        
        // Update state
        fa.reserve = remaining_reserve;
        fa.last_withdrawal = now;
        
        // Transfer APT
        let contract_signer = object::generate_signer_for_extending(&fa.extend);
        coin::transfer<AptosCoin>(&contract_signer, signer::address_of(admin), amount);
        
        // Emit event
        event::emit(ReserveWithdrawn {
            creator: fa.creator,
            symbol: fa.symbol,
            amount_withdrawn: amount,
            remaining_reserve: fa.reserve,
            timestamp: now,
        });
    }

    // Emergency withdrawal - chỉ dùng khi cần thiết
    public entry fun emergency_withdraw(
        admin: &signer,
        creator: address,
        symbol: vector<u8>,
        amount: u64,
        reason: vector<u8>
    ) acquires ManagedFA {
        let asset = get_metadata(creator, symbol);
        let object_addr = object::object_address(&asset);
        let fa = borrow_global_mut<ManagedFA>(object_addr);
        
        assert!(signer::address_of(admin) == fa.creator, 
                error::permission_denied(ENOT_OWNER));
        
        // Enable emergency mode
        fa.is_emergency = true;
        
        let contract_balance = coin::balance<AptosCoin>(object_addr);
        assert!(amount <= contract_balance, 
                error::invalid_argument(EINSUFFICIENT_FUNDS));
        
        // Update reserve
        if (amount <= fa.reserve) {
            fa.reserve = fa.reserve - amount;
        } else {
            fa.reserve = 0;
        };
        
        // Transfer APT
        let contract_signer = object::generate_signer_for_extending(&fa.extend);
        coin::transfer<AptosCoin>(&contract_signer, signer::address_of(admin), amount);
        
        // Emit event
        event::emit(EmergencyWithdrawn {
            creator: fa.creator,
            symbol: fa.symbol,
            amount_withdrawn: amount,
            reason,
            timestamp: aptos_framework::timestamp::now_seconds(),
        });
    }

    // Bonding curve cho việc mua token - giá tăng khi circulating supply tăng
    fun compute_buy_amount(k: u64, current_circulating: u64, apt_paid: u64): u64 {
        // Giá tăng theo số lượng circulating (càng nhiều token bán ra, giá càng cao)
        let price_multiplier = k + (current_circulating / 1000000);
        if (price_multiplier == 0) {
            apt_paid
        } else {
            apt_paid / price_multiplier
        }
    }

    // Bonding curve cho việc bán token - giá giảm khi bán
    fun compute_sell_amount(k: u64, current_circulating: u64, token_amount: u64): u64 {
        // Tính APT nhận được khi bán - dựa trên circulating supply sau khi bán
        let new_circulating = current_circulating - token_amount;
        let price_multiplier = k + (new_circulating / 1000000);
        if (price_multiplier == 0) {
            token_amount
        } else {
            token_amount * price_multiplier
        }
    }
}