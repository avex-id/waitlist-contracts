module mini_games::nft_lottery {
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
    use aptos_framework::type_info;
    use aptos_framework::randomness;

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
    /// function depriciated
    const E_DEPRICIATED : u64 = 8;
    /// you can select a maximum of 10 spins, and a minimum of 1 spin
    const E_SPIN_NUM_OUT_OF_BOUND: u64 = 9;

    const DIVISOR: u64 = 100;
    const MULTIPLIER: u64 = 10;
    const FEE_MULTIPLIER: u64 = 10;
    const WAITLIST_COINS_PRICE_PER_APTOS: u64 = 3000;
    const WAITLIST_COINS_PRICE_PER_APTOS_DIVISOR: u64 = 100000000;
    const MAX_SPINS:u64 = 10;
    const BASE_FEE_MULTIPLIER: u64 = 3;


    #[event]
    struct RewardEvent has drop, store {
        reward_type: String,
        reward_amount: u64,
        game_address: Option<address>,
        player: address,
        timestamp: u64,
    }

    #[event]
    struct RewardEventV2 has drop, store {
        reward_type: String,
        reward_amount: u64,
        game_address: Option<address>,
        player: address,
        bet_amount: u64,
        coin_type: String,
    }

    struct LotteryManager has key {
        apt_balance: Coin<AptosCoin>,
        nft_v1: vector<Object<NFTStore>>,
        nft_v2: vector<Object<NFTV2Store>>,
        active: bool,
    }

    struct Counter has key {
        counter: u64,
    }

    struct NFTResponse has drop {
        token_name: String,
        token_floor_price: u64,
        store: Object<NFTStore>,
    }

    struct NFTResponseV2 has drop {
        token_address: Object<TokenV2>,
        token_floor_price: u64,
        store: Object<NFTV2Store>,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct NFTStore has key, store {
        token: TokenV1,
        token_floor_price: u64,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct NFTV2Store has key, store {
        token_v2: Object<TokenV2>,
        token_floor_price: u64,
        extend_ref: ExtendRef,
        delete_ref: DeleteRef
    }

    struct Rewards has key {
        rewards: Table<address, Reward>,
    }

    struct Reward has key, store {
        nft: vector<Object<NFTStore>>,
        nft_v2: vector<Object<NFTV2Store>>,
        apt: Coin<AptosCoin>,
        free_spin: vector<u64>,
        raffle_ticket: u64,
        waitlist_coins: u64,
    }

    fun init_module(admin: &signer) {
        // Initialize the lottery manager
        assert!(signer::address_of(admin) == @mini_games, E_ERROR_UNAUTHORIZED);
        move_to(&resource_account::get_signer(), LotteryManager {
            apt_balance: coin::zero<AptosCoin>(),
            nft_v1: vector::empty<Object<NFTStore>>(),
            nft_v2: vector::empty<Object<NFTV2Store>>(),
            active: true,
        });

        // Initialize the rewards
        move_to(&resource_account::get_signer(), Rewards {
            rewards: table::new<address, Reward>(),
        });
    }

    entry fun pause_lottery(sender: &signer) acquires LotteryManager {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let lottery_manager = borrow_global_mut<LotteryManager>(resource_account::get_address());
        lottery_manager.active = false;
    }

    entry fun resume_lottery(sender: &signer) acquires LotteryManager {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let lottery_manager = borrow_global_mut<LotteryManager>(resource_account::get_address());
        lottery_manager.active = true;
    }

    public entry fun add_apt(sender: &signer, amount: u64) acquires LotteryManager {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let coin = coin::withdraw<AptosCoin>(sender, amount);
        let lottery_manager = borrow_global_mut<LotteryManager>(resource_account::get_address());
        coin::merge<AptosCoin>(&mut lottery_manager.apt_balance, coin);
    }

    public entry fun withdraw_apt(sender: &signer, amount: u64) acquires LotteryManager {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let lottery_manager = borrow_global_mut<LotteryManager>(resource_account::get_address());
        let coin = coin::extract(&mut lottery_manager.apt_balance, amount);
        aptos_account::deposit_coins(signer::address_of(sender), coin);
    }

    public entry fun add_nft_v1(
        sender: &signer,
        token_creator: address,
        token_collection: String,
        token_name: String,
        token_property_version: u64,
        token_floor_price: u64,
    ) acquires LotteryManager {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        // assert!(check_status(), E_ERROR_LOTTERY_PAUSED);

        let token_id = tokenv1::create_token_id_raw(
            token_creator,
            token_collection,
            token_name,
            token_property_version
        );
        let token = tokenv1::withdraw_token(sender, token_id, 1);

        // Generate new object for NFTStore
        let obj_ref = object::create_object(resource_account::get_address());
        let obj_signer = object::generate_signer(&obj_ref);

        move_to(&obj_signer, NFTStore {
            token,
            token_floor_price,
        });
        let obj = object::object_from_constructor_ref(&obj_ref);
        let lottery_manager = borrow_global_mut<LotteryManager>(resource_account::get_address());
        vector::push_back(&mut lottery_manager.nft_v1, obj);
    }

    public entry fun add_nft_v2(
        sender: &signer,
        token_v2: Object<TokenV2>,
        token_floor_price: u64,
    ) acquires LotteryManager {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        // assert!(check_status(), E_ERROR_LOTTERY_PAUSED);

        // Generate new object for NFTV2Wrap
        let obj_ref = object::create_object(resource_account::get_address());
        let obj_signer = object::generate_signer(&obj_ref);
        let extend_ref = object::generate_extend_ref(&obj_ref);
        let delete_ref = object::generate_delete_ref(&obj_ref);

        move_to(&obj_signer, NFTV2Store {
            token_v2,
            token_floor_price,
            extend_ref,
            delete_ref
        });
        let obj = object::object_from_constructor_ref(&obj_ref);
        object::transfer_to_object(sender, token_v2, obj);

        let lottery_manager = borrow_global_mut<LotteryManager>(resource_account::get_address());
        vector::push_back(&mut lottery_manager.nft_v2, obj);
    }

    public entry fun change_floor_price_v1(
        sender: &signer,
        nft_store: Object<NFTStore>,
        token_floor_price: u64
    ) acquires LotteryManager, NFTStore {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        assert!(check_status(), E_ERROR_LOTTERY_PAUSED);

        let nft_store = borrow_global_mut<NFTStore>(object::object_address(&nft_store));
        nft_store.token_floor_price = token_floor_price;
    }

    public entry fun change_floor_price_v2(
        sender: &signer,
        nft_v2_store: Object<NFTV2Store>,
        token_floor_price: u64
    ) acquires LotteryManager, NFTV2Store {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        assert!(check_status(), E_ERROR_LOTTERY_PAUSED);

        let nft_v2_store = borrow_global_mut<NFTV2Store>(object::object_address(&nft_v2_store));
        nft_v2_store.token_floor_price = token_floor_price;
    }

    #[randomness]
    entry fun play_v1_multiple(
        sender: &signer,
        winning_percentage: u64,
        use_free_spin: bool,  // Use free spin if available
        nft_store: Object<NFTStore>,
        number_of_spins: u64,
    ) acquires  LotteryManager, NFTStore, Rewards{
        assert!(check_is_nft_v1_still_valid(nft_store) , E_ERROR_NFT_ALREADY_WON);
        assert!(number_of_spins <= MAX_SPINS, E_SPIN_NUM_OUT_OF_BOUND);
        assert!(number_of_spins > 0, E_ERROR_UNAUTHORIZED);
        let i = 0;
        while (i < number_of_spins) {
            if (check_is_nft_v1_still_valid(nft_store)) {
                play_v1(sender, winning_percentage, use_free_spin, nft_store);
                i = i + 1;
            } else {
                break
            }
        }
    }

    #[randomness]
    entry fun play_v1(
        sender: &signer,
        winning_percentage: u64,
        use_free_spin: bool,  // Use free spin if available
        nft_store: Object<NFTStore>,
    ) acquires LotteryManager, NFTStore, Rewards {
        assert!(check_status(), E_ERROR_LOTTERY_PAUSED);
        assert!(check_percentage_bounds(winning_percentage), E_ERROR_PERCENTAGE_OUT_OF_BOUNDS);
        assert!(check_is_nft_v1_still_valid(nft_store) , E_ERROR_NFT_ALREADY_WON);

        let token_floor_price = borrow_global<NFTStore>(object::object_address(&nft_store)).token_floor_price;
        let spin_cost = (token_floor_price * winning_percentage * MULTIPLIER) / (DIVISOR * 100) * BASE_FEE_MULTIPLIER;


        if(!table::contains(&borrow_global<Rewards>(resource_account::get_address()).rewards, signer::address_of(sender))){
            table::add(&mut borrow_global_mut<Rewards>(resource_account::get_address()).rewards, signer::address_of(sender), Reward {
                nft: vector::empty<Object<NFTStore>>(),
                nft_v2: vector::empty<Object<NFTV2Store>>(),
                apt: coin::zero<AptosCoin>(),
                free_spin: vector::empty<u64>(),
                raffle_ticket: 0,
                waitlist_coins: 0,
            });
        };

        // Handle free spin
        let player_rewards = table::borrow_mut(&mut borrow_global_mut<Rewards>(resource_account::get_address()).rewards, signer::address_of(sender));
        let free_spin_length = vector::length(&player_rewards.free_spin);
        if (use_free_spin && free_spin_length > 0){
            winning_percentage = vector::remove(&mut player_rewards.free_spin, 0);
        } else {
            let fees = coin::withdraw<AptosCoin>(sender, (spin_cost));
            house_treasury::merge_coins<AptosCoin>(fees);
        };

        let random_num = randomness::u64_range(0, 10000);

        let tier = allot_tier(winning_percentage * MULTIPLIER, random_num);
        handle_tier(sender, tier, winning_percentage, spin_cost , option::some(nft_store), option::none(), 0);
    }

    #[randomness]
    entry fun play_v2_multiple(
        sender: &signer,
        winning_percentage: u64,
        use_free_spin: bool,  // Use free spin if available
        nft_v2_store: Object<NFTV2Store>,
        number_of_spins: u64,
    ) acquires  LotteryManager, NFTV2Store, Rewards{
        assert!(check_is_nft_v2_still_valid(nft_v2_store), E_ERROR_NFT_ALREADY_WON);
        assert!(number_of_spins <= MAX_SPINS, E_SPIN_NUM_OUT_OF_BOUND);
        assert!(number_of_spins > 0, E_ERROR_UNAUTHORIZED);
        let i = 0;
        while (i < number_of_spins) {
            if (check_is_nft_v2_still_valid(nft_v2_store)) {
                play_v2_internal(sender, winning_percentage, use_free_spin, nft_v2_store);
                i = i + 1;
            } else {
                break
            }
        }
    }

    fun play_v2_internal(
        sender: &signer,
        winning_percentage: u64,
        use_free_spin: bool,  // Use free spin if available
        nft_v2_store: Object<NFTV2Store>,
    ) acquires LotteryManager, NFTV2Store, Rewards {
        assert!(check_status(), E_ERROR_LOTTERY_PAUSED);
        assert!(check_percentage_bounds(winning_percentage), E_ERROR_PERCENTAGE_OUT_OF_BOUNDS);
        assert!(check_is_nft_v2_still_valid(nft_v2_store), E_ERROR_NFT_ALREADY_WON);

        let token_floor_price = borrow_global<NFTV2Store>(object::object_address(&nft_v2_store)).token_floor_price;
        let spin_cost = (token_floor_price * winning_percentage * MULTIPLIER) / (DIVISOR * 100) * BASE_FEE_MULTIPLIER;

        if(!table::contains(&borrow_global<Rewards>(resource_account::get_address()).rewards, signer::address_of(sender))){
            table::add(&mut borrow_global_mut<Rewards>(resource_account::get_address()).rewards, signer::address_of(sender), Reward {
                nft: vector::empty<Object<NFTStore>>(),
                nft_v2: vector::empty<Object<NFTV2Store>>(),
                apt: coin::zero<AptosCoin>(),
                free_spin: vector::empty<u64>(),
                raffle_ticket: 0,
                waitlist_coins: 0,
            });
        };

        // Handle free spin
        let player_rewards = table::borrow_mut(&mut borrow_global_mut<Rewards>(resource_account::get_address()).rewards, signer::address_of(sender));
        let free_spin_length = vector::length(&player_rewards.free_spin);
        if (use_free_spin && free_spin_length > 0){
            winning_percentage = vector::remove(&mut player_rewards.free_spin, 0);
        } else {
            let fees = coin::withdraw<AptosCoin>(sender, (spin_cost ));
            house_treasury::merge_coins<AptosCoin>(fees);
        };

        let random_num = randomness::u64_range(0, 10000);
        let tier = allot_tier(winning_percentage * MULTIPLIER, random_num);
        handle_tier(sender, tier, winning_percentage, spin_cost , option::none(), option::some(nft_v2_store), 1);
    }

    public entry fun play_v2(
        _sender: &signer,
        _winning_percentage: u64,
        _use_free_spin: bool,  // Use free spin if available
        _nft_v2_store: Object<NFTV2Store>,
    )  {
        assert!(false, E_DEPRICIATED);
    }

    entry fun claim(sender: &signer)
    acquires Rewards, NFTStore, NFTV2Store, /*LotteryManager*/ {
        // assert!(check_status(), E_ERROR_LOTTERY_PAUSED);

        // Fetch the rewards of the player
        let sender_address = signer::address_of(sender);
        let rewards = &mut borrow_global_mut<Rewards>(resource_account::get_address()).rewards;
        let player_rewards = table::borrow_mut(rewards, sender_address);

        // Claim v1 NFTs if any
        vector::for_each<Object<NFTStore>>(player_rewards.nft, |nft| {
            let NFTStore { token, token_floor_price : _token_floor_price } = move_from<NFTStore>(object::object_address(&nft));
            tokenv1::deposit_token(sender, token);
            object::transfer(&resource_account::get_signer(), nft, sender_address);
        });
        player_rewards.nft = vector::empty<Object<NFTStore>>();

        // Claim v2 NFTs if any
        vector::for_each<Object<NFTV2Store>>(player_rewards.nft_v2, |nft_v2| {
            let NFTV2Store {
                token_v2,
                token_floor_price: _token_floor_price,
                extend_ref,
                delete_ref
            } = move_from<NFTV2Store>(object::object_address(&nft_v2));

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
    //
    // entry fun remove_added_nfts(sender: &signer) acquires LotteryManager, NFTStore, NFTV2Store {
    //     assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
    //
    //     let nft_v1 = borrow_global_mut<LotteryManager>(resource_account::get_address()).nft_v1;
    //     vector::for_each<Object<NFTStore>>(nft_v1, |nft| {
    //         let NFTStore { token, token_floor_price } = move_from(object::object_address(&nft));
    //         tokenv1::deposit_token(sender, token);
    //     });
    //
    //     let nft_v2 = borrow_global_mut<LotteryManager>(resource_account::get_address()).nft_v2;
    //     vector::for_each<Object<NFTV2Store>>(nft_v2, |nft| {
    //         let NFTV2Store {
    //             token_v2,
    //             token_floor_price,
    //             extend_ref,
    //             delete_ref
    //         } = move_from(object::object_address(&nft));
    //
    //         let token_signer = object::generate_signer_for_extending(&extend_ref);
    //         object::transfer(&token_signer, token_v2, signer::address_of(sender));
    //         object::delete(delete_ref);
    //     });
    //
    //     let lottery_manager = borrow_global_mut<LotteryManager>(resource_account::get_address());
    //
    //     lottery_manager.nft_v1 = vector::empty<Object<NFTStore>>();
    //     lottery_manager.nft_v2 = vector::empty<Object<NFTV2Store>>();
    // }


    fun check_percentage_bounds(percentage: u64): bool {
        let allowed_percentages: vector<u64> = vector[1, 2, 3, 4, 5];
        vector::contains(&allowed_percentages, &percentage)
    }


    fun handle_tier(
        sender: &signer,
        tier: u64,
        winning_percentage: u64,
        fee_amount: u64,
        nft_store: Option<Object<NFTStore>>,
        nft_v2_store: Option<Object<NFTV2Store>>,
        type: u8
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
                vector::push_back(sender_nfts, *option::borrow(&nft_store));
                let nfts = &mut borrow_global_mut<LotteryManager>(resource_account::get_address()).nft_v1;
                vector::remove_value(nfts, option::borrow(&nft_store));
                emit_rewards_v2_event(string::utf8(b"NFT v1"), 1, reward_address, signer::address_of(sender), fee_amount, type_info::type_name<AptosCoin>());
            } else if (type == 1) {
                let sender_nfts_v2 = &mut player_rewards.nft_v2;
                vector::push_back(sender_nfts_v2, *option::borrow(&nft_v2_store));
                let nfts_v2 = &mut borrow_global_mut<LotteryManager>(resource_account::get_address()).nft_v2;
                vector::remove_value(nfts_v2, option::borrow(&nft_v2_store));
                emit_rewards_v2_event(string::utf8(b"NFT v2"), 1, reward_address, signer::address_of(sender), fee_amount, type_info::type_name<AptosCoin>());
            } else {
                abort E_ERROR_INVALID_TYPE
            }
        } else if (tier == 1) {
            // 2x apt_balance amount
            let coin_amount = 2 * fee_amount;
            let coin = house_treasury::extract_coins<AptosCoin>(coin_amount);
            coin::merge(&mut player_rewards.apt, coin);

            let reward_type = string::utf8(b"2x APT REWARD");
            emit_rewards_v2_event(reward_type, coin_amount, reward_address, signer::address_of(sender), fee_amount, type_info::type_name<AptosCoin>())
        } else if (tier == 2) {
            // 1 free spin
            vector::push_back(&mut player_rewards.free_spin, winning_percentage);
            emit_rewards_v2_event(string::utf8(b"Free Spin"), 1, reward_address, signer::address_of(sender), fee_amount, type_info::type_name<AptosCoin>());
        } else if (tier == 3) {
            // 50% of the apt_balance amount
            let coin_amount = fee_amount / 2;
            let coin = house_treasury::extract_coins<AptosCoin>(coin_amount);
            coin::merge(&mut player_rewards.apt, coin);
            let reward_type = string::utf8(b"50% APT CASHBACK");
            // string::append(&mut reward_type, string::utf8(bcs::to_bytes(&coin_amount)));
            emit_rewards_v2_event(reward_type, coin_amount, reward_address, signer::address_of(sender), fee_amount, type_info::type_name<AptosCoin>());
        } else if (tier == 4) {
            // 40% of the apt_balance amount
            let coin_amount = (fee_amount * 4) / 10;
            let coin = house_treasury::extract_coins<AptosCoin>(coin_amount);
            coin::merge(&mut player_rewards.apt, coin);

            let reward_type = string::utf8(b"40% APT CASHBACK");
            // string::append(&mut reward_type, string::utf8(bcs::to_bytes(&coin_amount)));
            emit_rewards_v2_event(reward_type, coin_amount, reward_address, signer::address_of(sender), fee_amount, type_info::type_name<AptosCoin>());
        } else if (tier == 5) {
            // 30% of the apt_balance amount
            let coin_amount = (fee_amount * 3) / 10;
            let coin = house_treasury::extract_coins<AptosCoin>(coin_amount);
            coin::merge(&mut player_rewards.apt, coin);

            let reward_type = string::utf8(b"30% APT CASHBACK");
            emit_rewards_v2_event(reward_type, coin_amount, reward_address, signer::address_of(sender), fee_amount, type_info::type_name<AptosCoin>());
        } else if (tier == 6) {
            // 1 raffle ticket
            player_rewards.raffle_ticket = player_rewards.raffle_ticket + 1;
            emit_rewards_v2_event(string::utf8(b"Raffle Ticket"), 1, reward_address, signer::address_of(sender), fee_amount, type_info::type_name<AptosCoin>());
        } else if (tier == 7) {
            // waitlist coins at price - 1 apt = 3000 coins
            let waitlist_coins_amount = (WAITLIST_COINS_PRICE_PER_APTOS * fee_amount) / WAITLIST_COINS_PRICE_PER_APTOS_DIVISOR;
            player_rewards.waitlist_coins = player_rewards.waitlist_coins + waitlist_coins_amount;
            emit_rewards_v2_event(string::utf8(b"Waitlist Coins"), waitlist_coins_amount, reward_address, signer::address_of(sender), fee_amount, type_info::type_name<AptosCoin>());
        } else {
            abort E_REWARD_TIER_OUT_OF_BOUNDS
        };
    }


    fun check_is_nft_v1_still_valid(nft_store: Object<NFTStore>): bool  acquires LotteryManager{
        let nft_v1 = borrow_global<LotteryManager>(resource_account::get_address()).nft_v1;

        vector::contains(&nft_v1, &nft_store)
    }

    fun check_is_nft_v2_still_valid(nft_v2_store: Object<NFTV2Store>): bool  acquires LotteryManager{
        let nft_v2 = borrow_global<LotteryManager>(resource_account::get_address()).nft_v2;

        vector::contains(&nft_v2, &nft_v2_store)
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

    fun check_status(): bool acquires LotteryManager {
        borrow_global<LotteryManager>(resource_account::get_address()).active
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

    fun emit_rewards_v2_event(reward_type: String, reward_amount: u64, game_address: Option<address>, player: address, bet_amount: u64, coin_type:String){
        0x1::event::emit(RewardEventV2 {
            reward_type,
            reward_amount,
            game_address,
            player,
            bet_amount,
            coin_type
        });
    }

    #[view]
    public fun see_resource_address(): address {
        resource_account::get_address()
    }

    #[view]
    public fun see_nft_details(): vector<NFTResponse>
    acquires LotteryManager, NFTStore {
        let nft_v1 = borrow_global<LotteryManager>(resource_account::get_address()).nft_v1;
        let response = vector::empty<NFTResponse>();

        vector::for_each<Object<NFTStore>>(nft_v1, |nft| {
            let nft_store = borrow_global<NFTStore>(object::object_address(&nft));
            let token = &nft_store.token;
            let token_floor_price = nft_store.token_floor_price;

            let token_id = tokenv1::get_token_id(token);
            let (_, _, token_name, _) = tokenv1::get_token_id_fields(&token_id);
            vector::push_back(&mut response, NFTResponse {
                token_name,
                token_floor_price,
                store: nft,
            });
        });

        response
    }

    #[view]
    public fun see_nft_details_user_reward(user: address): vector<NFTResponse>
    acquires Rewards, NFTStore {
        // let response = vector::empty<NFTResponse>();

        let rewards = &mut borrow_global_mut<Rewards>(resource_account::get_address()).rewards;

        let response = if(table::contains(rewards, user)){
            let player_rewards = table::borrow_mut(rewards, user);
            let nft_v1 = player_rewards.nft;
            let response = vector::empty<NFTResponse>();

            vector::for_each<Object<NFTStore>>(nft_v1, |nft| {
                let nft_store = borrow_global<NFTStore>(object::object_address(&nft));
                let token = &nft_store.token;
                let token_floor_price = nft_store.token_floor_price;

                let token_id = tokenv1::get_token_id(token);
                let (_, _, token_name, _) = tokenv1::get_token_id_fields(&token_id);
                vector::push_back(&mut response, NFTResponse {
                    token_name,
                    token_floor_price,
                    store: nft,
                });
            });

            response
        } else {
            vector::empty<NFTResponse>()
        };

        response
    }

    #[view]
    public fun see_nft_v2_details(): vector<NFTResponseV2>
    acquires LotteryManager, NFTV2Store {
        let nft_v2 = borrow_global<LotteryManager>(resource_account::get_address()).nft_v2;
        let response = vector::empty<NFTResponseV2>();

        vector::for_each<Object<NFTV2Store>>(nft_v2, |nft| {
            let nft_v2_store = borrow_global<NFTV2Store>(object::object_address(&nft));
            let token_v2 = nft_v2_store.token_v2;
            let token_floor_price = nft_v2_store.token_floor_price;
            vector::push_back(&mut response, NFTResponseV2 {
                token_address: token_v2,
                token_floor_price,
                store: nft,
            });
        });

        response
    }

    #[view]
    public fun see_nft_v2_details_user_reward(user: address): vector<NFTResponseV2>
    acquires Rewards, NFTV2Store {
        let rewards = &mut borrow_global_mut<Rewards>(resource_account::get_address()).rewards;

        let response = if(table::contains(rewards, user)){
            let player_rewards = table::borrow_mut(rewards, user);
            let nft_v2 = player_rewards.nft_v2;
            let response = vector::empty<NFTResponseV2>();

            vector::for_each<Object<NFTV2Store>>(nft_v2, |nft| {
                let nft_v2_store = borrow_global<NFTV2Store>(object::object_address(&nft));
                let token_v2 = nft_v2_store.token_v2;
                let token_floor_price = nft_v2_store.token_floor_price;
                vector::push_back(&mut response, NFTResponseV2 {
                    token_address: token_v2,
                    token_floor_price,
                    store: nft,
                });
            });

            response
        } else {
            vector::empty<NFTResponseV2>()
        };

        response
    }

    #[view]
    public fun see_nft_v1_names(): vector<String>
    acquires LotteryManager, NFTStore {
        let nft_v1 = borrow_global<LotteryManager>(resource_account::get_address()).nft_v1;
        let names = vector::empty<String>();
        vector::for_each<Object<NFTStore>>(nft_v1, |nft| {
            let token = &borrow_global<NFTStore>(object::object_address(&nft)).token;
            let token_id = tokenv1::get_token_id(token);
            let (_, _, token_name, _) = tokenv1::get_token_id_fields(&token_id);
            vector::push_back(&mut names, token_name);
        });
        names
    }

    #[view]
    public fun see_nft_v2_address(): vector<Object<TokenV2>>
    acquires LotteryManager, NFTV2Store {
        let nft_v2 = borrow_global<LotteryManager>(resource_account::get_address()).nft_v2;
        let addresses = vector::empty<Object<TokenV2>>();
        vector::for_each<Object<NFTV2Store>>(nft_v2, |nft| {
            let token_v2 = borrow_global<NFTV2Store>(object::object_address(&nft)).token_v2;
            vector::push_back(&mut addresses, token_v2);
        });
        addresses
    }

}