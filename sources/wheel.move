module mini_games::wheel {
    use std::bcs;
    use std::hash;
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{Self, String};
    use std::vector;

    use aptos_std::object::{Self, Object, DeleteRef, ExtendRef};
    use aptos_token::token::{Self as tokenv1, Token as TokenV1};
    use aptos_token_objects::token::{Token as TokenV2};

    use aptos_framework::aptos_account;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::table::{Self, Table};
    use aptos_framework::timestamp;
    use aptos_framework::transaction_context;

    use mini_games::resource_account_manager as resource_account;
    use mini_games::raffle;
    use mini_games::house_treasury;

    /// you are not authorized to call this function
    const E_ERROR_UNAUTHORIZED: u64 = 1;
    /// spin tier provided is not allowed, allowed tiers are 1, 2, 3, 4, 5
    const E_ERROR_PERCENTAGE_OUT_OF_BOUNDS: u64 = 2;
    /// reward tier calculated is out of bounds
    const E_REWARD_TIER_OUT_OF_BOUNDS: u64 = 3;
    /// random number generated is out of bounds
    const E_RANDOM_NUM_OUT_OF_BOUNDS: u64 = 4;
    /// invalid nft type identifier
    const E_ERROR_INVALID_TYPE: u64 = 5;
    /// lottery is paused currently, please try again later or contact defy team
    const E_ERROR_LOTTERY_PAUSED: u64 = 6;
    /// this nft has already been won by the another player
    const E_ERROR_NFT_ALREADY_WON: u64 = 7;

    const DIVISOR: u64 = 100;
    const MULTIPLIER: u64 = 10;
    const FEE_MULTIPLIER: u64 = 10;
    const WAITLIST_COINS_PRICE_PER_APTOS: u64 = 3000;
    const WAITLIST_COINS_PRICE_PER_APTOS_DIVISOR: u64 = 100000000;


    #[event]
    struct RewardEvent has drop, store {
        reward_type: String,
        reward_amount: u64,
        game_address: Option<address>,
        player: address,
        timestamp: u64,
    }

    struct GameConfig has key {
        active: bool,
        fees_apt: u64,
    }

    struct NFTs has key {
        nft_v1_vector : vector<NFT_V1>,
        nft_v2_vector : vector<NFT_V2>,
    }

    struct NFT_V1 has key {
        token_creator: address,
        token_collection: String,
        token_name: String,
        token_property_version: u64,
    }

    struct NFT_V2 has key {
        token_v2: address,
    }

    struct Rewards has key {
        rewards: Table<address, Reward>,
    }

    struct Reward has key, store {
        nft: vector<NFT_V1>,
        nft_v2: vector<NFT_V2>,
        apt: Coin<AptosCoin>,
        free_spin: u64,
        raffle_ticket: u64,
        waitlist_coins: u64,
    }


    fun init_module(admin: &signer) {
        // Initialize the lottery manager
        assert!(signer::address_of(admin) == @mini_games, E_ERROR_UNAUTHORIZED);
        move_to<NFTs>(&resource_account::get_signer(), NFTs {
            nft_v1_vector: vector::empty<NFT_V1>(),
            nft_v2_vector: vector::empty<NFT_V2>(),
        });

        move_to<GameConfig>(&resource_account::get_signer(), GameConfig {
            active: false,
            fees_apt: 10000000,
        });
    }

    entry fun pause_lottery(sender: &signer) acquires GameConfig {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let lottery_manager = borrow_global_mut<GameConfig>(resource_account::get_address());
        lottery_manager.active = false;
    }

    entry fun resume_lottery(sender: &signer) acquires GameConfig {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let lottery_manager = borrow_global_mut<GameConfig>(resource_account::get_address());
        lottery_manager.active = true;
    }

    public entry fun add_nft_v1(
        sender: &signer,
        token_creator: address,
        token_collection: String,
        token_name: String,
        token_property_version: u64,
    ) acquires NFTs {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        // assert!(check_status(), E_ERROR_LOTTERY_PAUSED);

        let nfts_resource = borrow_global_mut<NFTs>(resource_account::get_address());
        let nft_v1 = NFT_V1 {
            token_creator,
            token_collection,
            token_name,
            token_property_version,
        };

        vector::push_back(&mut nfts_resource.nft_v1_vector, nft_v1);

        let token_id = tokenv1::create_token_id_raw(
            token_creator,
            token_collection,
            token_name,
            token_property_version
        );
        let token = tokenv1::withdraw_token(sender, token_id, 1);
        tokenv1::deposit_token(&resource_account::get_signer(), token);

    }

    public entry fun add_nft_v2(
        sender: &signer,
        token_v2: Object<TokenV2>,
    ) acquires  NFTs {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        // assert!(check_status(), E_ERROR_LOTTERY_PAUSED);
        let nfts_resource = borrow_global_mut<NFTs>(resource_account::get_address());
        let nft_v2 = NFT_V2 {
            token_v2 : object::object_address(&token_v2),
        };
        vector::push_back(&mut nfts_resource.nft_v2_vector, nft_v2);
        object::transfer(sender, token_v2, resource_account::get_address());
    }

    entry fun play(
        sender: &signer,
        use_free_spin: bool
    ) acquires GameConfig, NFTs, Rewards {
        assert!(check_status(), E_ERROR_LOTTERY_PAUSED);

        if(!table::contains(&borrow_global<Rewards>(resource_account::get_address()).rewards, signer::address_of(sender))){
            table::add(&mut borrow_global_mut<Rewards>(resource_account::get_address()).rewards, signer::address_of(sender), Reward {
                nft: vector::empty<NFT_V1>(),
                nft_v2: vector::empty<NFT_V2>(),
                apt: coin::zero<AptosCoin>(),
                free_spin: 0,
                raffle_ticket: 0,
                waitlist_coins: 0,
            });
        };

        // Handle free spin
        let player_rewards = table::borrow_mut(&mut borrow_global_mut<Rewards>(resource_account::get_address()).rewards, signer::address_of(sender));
        let free_spin = player_rewards.free_spin;
        if (use_free_spin && free_spin > 0){
            player_rewards.free_spin = free_spin - 1;
        } else {
            process_fee(sender);
        };

        let random_num = rand_u64_range();
        handle_tier(sender, random_num);
    }

    entry fun claim(sender: &signer)
    acquires Rewards {
        assert!(check_status(), E_ERROR_LOTTERY_PAUSED);

        // Fetch the rewards of the player
        let sender_address = signer::address_of(sender);
        let rewards = &mut borrow_global_mut<Rewards>(resource_account::get_address()).rewards;
        let player_rewards = table::borrow_mut(rewards, sender_address);

        // Claim v1 NFTs if any
        vector::for_each<Object<NFTStore>>(player_rewards.nft, |nft| {
            let NFTStore { token, token_floor_price } = move_from(object::object_address(&nft));
            tokenv1::deposit_token(sender, token);
            object::transfer(&resource_account::get_signer(), nft, sender_address);
        });
        player_rewards.nft = vector::empty<Object<NFTStore>>();

        // Claim v2 NFTs if any
        vector::for_each<Object<NFTV2Store>>(player_rewards.nft_v2, |nft_v2| {
            let NFTV2Store {
                token_v2,
                token_floor_price,
                extend_ref,
                delete_ref
            } = move_from(object::object_address(&nft_v2));

            let token_signer = object::generate_signer_for_extending(&extend_ref);
            object::transfer(&token_signer, token_v2, sender_address);
            object::delete(delete_ref);
            // object::transfer(&resource_account::get_signer(), nft_v2, sender_address);
        });



        player_rewards.nft_v2 = vector::empty<Object<NFTV2Store>>();

        // Claim APT if any
        let apt = &mut player_rewards.apt;
        let value = coin::value(apt);
        let coin = coin::extract(apt, value);
        aptos_account::deposit_coins(sender_address, coin);

        // Claim raffle tickets if any
        let amount = player_rewards.raffle_ticket;
        if (amount > 0) {
            raffle::mint_ticket(&resource_account::get_signer(), sender_address, amount);
            player_rewards.raffle_ticket = 0;
        }
    }

    // entry fun remove_added_nfts(sender: &signer) acquires LotteryManager, NFTStore, NFTV2Store {
    //     assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);

    //     let nft_v1 = borrow_global_mut<LotteryManager>(resource_account::get_address()).nft_v1;
    //     vector::for_each<Object<NFTStore>>(nft_v1, |nft| {
    //         let NFTStore { token, token_floor_price } = move_from(object::object_address(&nft));
    //         tokenv1::deposit_token(sender, token);
    //     });

    //     let nft_v2 = borrow_global_mut<LotteryManager>(resource_account::get_address()).nft_v2;
    //     vector::for_each<Object<NFTV2Store>>(nft_v2, |nft| {
    //         let NFTV2Store {
    //             token_v2,
    //             token_floor_price,
    //             extend_ref,
    //             delete_ref
    //         } = move_from(object::object_address(&nft));

    //         let token_signer = object::generate_signer_for_extending(&extend_ref);
    //         object::transfer(&token_signer, token_v2, signer::address_of(sender));
    //         object::delete(delete_ref);
    //     });

    //     let lottery_manager = borrow_global_mut<LotteryManager>(resource_account::get_address());

    //     lottery_manager.nft_v1 = vector::empty<Object<NFTStore>>();
    //     lottery_manager.nft_v2 = vector::empty<Object<NFTV2Store>>();
    // }


    fun process_fee(sender: &signer) acquires GameConfig{
        let game_config = borrow_global<GameConfig>(resource_account::get_address());
        let fees = coin::withdraw<AptosCoin>(sender, game_config.fees_apt);
        house_treasury::merge_coins(fees);
    }

    fun rand_u64_range(): u64 {
        let tx_hash = transaction_context::get_transaction_hash();
        let timestamp = bcs::to_bytes(&timestamp::now_microseconds());
        vector::append(&mut tx_hash, timestamp);
        let hash = hash::sha3_256(tx_hash);
        let value = bytes_to_u64(hash);
        value % 10000
    }


    fun handle_tier(
        sender: &signer,
        random_num: u64
    ) acquires LotteryManager, Rewards {
        let rewards = &mut borrow_global_mut<Rewards>(resource_account::get_address()).rewards;
        if(!table::contains(rewards, signer::address_of(sender))){
            table::add(rewards, signer::address_of(sender), Reward {
                nft: vector::empty<Object<NFTStore>>(),
                nft_v2: vector::empty<Object<NFTV2Store>>(),
                apt: coin::zero<AptosCoin>(),
                free_spin: vector::empty<u64>(),
                raffle_ticket: 0,
                waitlist_coins: 0,
            })};

        let reward_address = if (type == 0) {
            option::some(object::object_address(option::borrow(&nft_store)))
        } else if (type == 1) {
            option::some(object::object_address(option::borrow(&nft_v2_store)))
        } else {
            option::none()
        };

        let player_rewards = table::borrow_mut(rewards, signer::address_of(sender));

        if (tier == 0) {
            if (type == 0){
                let sender_nfts = &mut player_rewards.nft;
                let nft_address = object::object_address(option::borrow(&nft_store));
                vector::push_back(sender_nfts, *option::borrow(&nft_store));
                let nfts = &mut borrow_global_mut<LotteryManager>(resource_account::get_address()).nft_v1;
                vector::remove_value(nfts, option::borrow(&nft_store));
                emit_event(string::utf8(b"NFT v1"), 1, option::some(nft_address), signer::address_of(sender));
            } else if (type == 1) {
                let sender_nfts_v2 = &mut player_rewards.nft_v2;
                let nft_v2_address = object::object_address(option::borrow(&nft_v2_store));
                vector::push_back(sender_nfts_v2, *option::borrow(&nft_v2_store));
                let nfts_v2 = &mut borrow_global_mut<LotteryManager>(resource_account::get_address()).nft_v2;
                vector::remove_value(nfts_v2, option::borrow(&nft_v2_store));
                emit_event(string::utf8(b"NFT v2"), 1, option::some(nft_v2_address), signer::address_of(sender));
            } else {
                abort E_ERROR_INVALID_TYPE
            }
        } else if (tier == 1) {
            // 2x apt_balance amount
            let apt = &mut borrow_global_mut<LotteryManager>(resource_account::get_address()).apt_balance;
            let coin_amount = 2 * fee_amount;
            let coin = coin::extract(apt, coin_amount);
            coin::merge(&mut player_rewards.apt, coin);

            let reward_type = string::utf8(b"2x APT REWARD");
            // string::append(&mut reward_type, string::utf8(bcs::to_bytes(&coin_amount)));
            emit_event(reward_type, coin_amount, reward_address, signer::address_of(sender));
        } else if (tier == 2) {
            // 1 free spin
            vector::push_back(&mut player_rewards.free_spin, winning_percentage);
            emit_event(string::utf8(b"Free Spin"), 1, reward_address, signer::address_of(sender));
        } else if (tier == 3) {
            // 50% of the apt_balance amount
            let apt = &mut borrow_global_mut<LotteryManager>(resource_account::get_address()).apt_balance;
            let coin_amount = fee_amount / 2;
            let coin = coin::extract(apt, coin_amount);
            coin::merge(&mut player_rewards.apt, coin);

            let reward_type = string::utf8(b"50% APT CASHBACK");
            // string::append(&mut reward_type, string::utf8(bcs::to_bytes(&coin_amount)));
            emit_event(reward_type, coin_amount, reward_address, signer::address_of(sender));
        } else if (tier == 4) {
            // 40% of the apt_balance amount
            let apt = &mut borrow_global_mut<LotteryManager>(resource_account::get_address()).apt_balance;
            let coin_amount = (fee_amount * 4) / 10;
            let coin = coin::extract(apt, coin_amount);
            coin::merge(&mut player_rewards.apt, coin);

            let reward_type = string::utf8(b"40% APT CASHBACK");
            // string::append(&mut reward_type, string::utf8(bcs::to_bytes(&coin_amount)));
            emit_event(reward_type, coin_amount, reward_address, signer::address_of(sender));
        } else if (tier == 5) {
            // 30% of the apt_balance amount
            let apt = &mut borrow_global_mut<LotteryManager>(resource_account::get_address()).apt_balance;
            let coin_amount = (fee_amount * 3) / 10;
            let coin = coin::extract(apt, coin_amount);
            coin::merge(&mut player_rewards.apt, coin);

            let reward_type = string::utf8(b"30% APT CASHBACK");
            // string::append(&mut reward_type, string::utf8(bcs::to_bytes(&coin_amount)));
            emit_event(reward_type, coin_amount, reward_address, signer::address_of(sender));
        } else if (tier == 6) {
            // 1 raffle ticket
            player_rewards.raffle_ticket = player_rewards.raffle_ticket + 1;
            emit_event(string::utf8(b"Raffle Ticket"), 1, reward_address, signer::address_of(sender));
        } else if (tier == 7) {
            // waitlist coins at price - 1 apt = 3000 coins
            let waitlist_coins_amount = (WAITLIST_COINS_PRICE_PER_APTOS * fee_amount) / WAITLIST_COINS_PRICE_PER_APTOS_DIVISOR;
            player_rewards.waitlist_coins = player_rewards.waitlist_coins + waitlist_coins_amount;
            emit_event(string::utf8(b"Waitlist Coins"), waitlist_coins_amount, reward_address, signer::address_of(sender));
        } else {
            abort E_REWARD_TIER_OUT_OF_BOUNDS
        };
    }



    fun allot_tier(n: u64, random_num: u64): u64 {
        if (random_num < n) {
            0
        } else if (random_num < ( 2 * n )) {
            1
        } else if (random_num < ( 2 * n + (5  * DIVISOR))) {
            2
        } else if (random_num < ( 2 * n + (13 * DIVISOR) )) {
            3
        } else if (random_num < ( 2 * n + (28 * DIVISOR) )) {
            4
        } else if (random_num < ( 2 * n + (48 * DIVISOR) )) {
            5
        } else if (random_num < ( n + (69 * DIVISOR) )) {
            6
        } else if (random_num < 100 * DIVISOR) {
            7
        } else {
            abort E_RANDOM_NUM_OUT_OF_BOUNDS
        }
    }

    fun check_status(): bool acquires GameConfig {
        borrow_global<GameConfig>(resource_account::get_address()).active
    }

    fun bytes_to_u64(bytes: vector<u8>): u64 {
        let value = 0u64;
        let i = 0u64;
        while (i < 8) {
            value = value | ((*vector::borrow(&bytes, i) as u64) << ((8 * (7 - i)) as u8));
            i = i + 1;
        };
        return value
    }

    fun emit_event(reward_type: String, reward_amount: u64, reward_address: Option<address>, player: address) {
        let game_address = reward_address;
        0x1::event::emit(RewardEvent {
            reward_type,
            reward_amount,
            game_address,
            player,
            timestamp: timestamp::now_microseconds(),
        });
    }

    #[view]
    public fun see_resource_address(): address {
        resource_account::get_address()
    }


}