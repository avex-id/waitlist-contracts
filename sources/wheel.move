module mini_games::wheel {

    use std::signer;
    use std::string;
    use std::string::{String};
    use std::vector;

    use aptos_std::object::{Self, Object};
    use aptos_token::token::{Self as tokenv1};
    use aptos_token_objects::token::{Token as TokenV2};

    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;
    use aptos_framework::randomness;
    use aptos_framework::type_info;

    use mini_games::resource_account_manager as resource_account;
    use mini_games::raffle;
    use mini_games::house_treasury;

    /// you are not authorized to call this function
    const E_ERROR_UNAUTHORIZED: u64 = 1;
    /// reward tier calculated is out of bounds
    const E_REWARD_TIER_OUT_OF_BOUNDS: u64 = 2;
    /// random number generated is out of bounds
    const E_RANDOM_NUM_OUT_OF_BOUNDS: u64 = 3;
    /// lottery is paused currently, please try again later or contact defy team
    const E_ERROR_LOTTERY_PAUSED: u64 = 4;
    /// no nfts left in the contract, wait sme time to play again they will be refilled
    const E_NO_NFTS_LEFT_IN_CONTRACT: u64 = 5;
    /// size of coin rewards tiers array invalid
    const E_INVALID_NUM_COIN_REWARD_TIERS: u64 = 6;
    /// values of coin rewards tiers array invalid, they should be in descending order
    const E_INVALID_VALUES_COIN_REWARD_TIERS: u64 = 7;


    const NUM_COIN_REWARD_TIERS: u64 = 4;


    struct GameConfig<phantom CoinType> has key {
        spin_fee: u64,
        active: bool,
        coin_reward_tiers_amounts: vector<u64>
    }

    struct NFTs has key, store {
        nft_v1_vector : vector<NFT_V1>,
        nft_v2_vector : vector<NFT_V2>,
    }

    struct NFT_V1 has drop, store{
        token_creator: address,
        token_collection: String,
        token_name: String,
        token_property_version: u64,
        image_url: String
    }

    struct NFT_V2 has store, drop {
        token_v2: address,
        token_name: String,
        image_url: String
    }

    struct UserRewards has key, store {
        nft_v1: vector<NFT_V1>,
        nft_v2: vector<NFT_V2>,
        raffle_ticket: u64,
        waitlist_coins: u64,
    }

    struct UserCoinRewards<phantom Cointype> has key, store {
        coin : Coin<Cointype>
    }

    #[event]
    struct PlayEvent has drop, store {
        player: address,
        reward_tier: u64,
        reward_type: String,
        reward_amount: u64,
        timestamp: u64,
    }

    #[event]
    struct DefyCoinsClaimEvent has drop, store {
        player: address,
        amount: u64,
        timestamp: u64,
    }

    entry fun add_or_change_game_config<CoinType>(sender: &signer, spin_fee: u64, coin_reward_tiers_amounts: vector<u64>) acquires GameConfig {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        assert!(vector::length(&coin_reward_tiers_amounts) == NUM_COIN_REWARD_TIERS, E_INVALID_NUM_COIN_REWARD_TIERS);
        let last_reward : u64 = *vector::borrow(&coin_reward_tiers_amounts, 0);
        for( i in  1..vector::length(&coin_reward_tiers_amounts)){
            let current_reward = *vector::borrow(&coin_reward_tiers_amounts, i);
            assert!(last_reward > current_reward, E_INVALID_VALUES_COIN_REWARD_TIERS);
            last_reward = current_reward;
        };
        if (! exists<GameConfig<CoinType>>(resource_account::get_address())){
            move_to<GameConfig<CoinType>>(&resource_account::get_signer(), GameConfig<CoinType>{
                spin_fee,
                active: true,
                coin_reward_tiers_amounts
            });
        } else{
            let game_manager = borrow_global_mut<GameConfig<CoinType>>(resource_account::get_address());
            game_manager.spin_fee = spin_fee;
            game_manager.coin_reward_tiers_amounts = coin_reward_tiers_amounts;
        }

    }

    entry fun pause_lottery<CoinType>(sender: &signer) acquires GameConfig {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let lottery_manager = borrow_global_mut<GameConfig<CoinType>>(resource_account::get_address());
        lottery_manager.active = false;
    }

    entry fun resume_lottery<CoinType>(sender: &signer) acquires GameConfig {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let lottery_manager = borrow_global_mut<GameConfig<CoinType>>(resource_account::get_address());
        lottery_manager.active = true;
    }

    public entry fun add_nft_v1(
        sender: &signer,
        token_creator: address,
        token_collection: String,
        token_name: String,
        token_property_version: u64,
        image_url: String
    ) acquires NFTs {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        // assert!(check_status(), E_ERROR_LOTTERY_PAUSED);

        if (!exists<NFTs>(resource_account::get_address())){
            move_to<NFTs>(&resource_account::get_signer(), NFTs {
                nft_v1_vector: vector::empty<NFT_V1>(),
                nft_v2_vector: vector::empty<NFT_V2>(),
            });
        };

        let nfts_resource = borrow_global_mut<NFTs>(resource_account::get_address());
        let nft_v1 = NFT_V1 {
            token_creator,
            token_collection,
            token_name,
            token_property_version,
            image_url
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

    public entry fun change_nft_image(
        sender: &signer,
        is_v1: bool,
        index: u64,
        image_url: String
    ) acquires NFTs {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let nfts = borrow_global_mut<NFTs>(resource_account::get_address());
        if (is_v1){
            let nft = vector::borrow_mut(&mut nfts.nft_v1_vector, index);
            nft.image_url = image_url;
        } else{
            let nft = vector::borrow_mut(&mut nfts.nft_v2_vector, index);
            nft.image_url = image_url;
        }
    }

    public entry fun change_nft_name(
        sender: &signer,
        index: u64,
        token_name: String
    ) acquires NFTs {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let nfts = borrow_global_mut<NFTs>(resource_account::get_address());
        let nft = vector::borrow_mut(&mut nfts.nft_v2_vector, index);
        nft.token_name = token_name;
    }

    public entry fun add_nft_v2(
        sender: &signer,
        token_v2: Object<TokenV2>,
        token_name: String,
        image_url: String
    ) acquires  NFTs {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        // assert!(check_status(), E_ERROR_LOTTERY_PAUSED);

        if (!exists<NFTs>(resource_account::get_address())){
            move_to<NFTs>(&resource_account::get_signer(), NFTs {
                nft_v1_vector: vector::empty<NFT_V1>(),
                nft_v2_vector: vector::empty<NFT_V2>(),
            });
        };

        let nfts_resource = borrow_global_mut<NFTs>(resource_account::get_address());
        let nft_v2 = NFT_V2 {
            token_v2 : object::object_address(&token_v2),
            token_name,
            image_url
        };
        vector::push_back(&mut nfts_resource.nft_v2_vector, nft_v2);
        object::transfer(sender, token_v2, resource_account::get_address());
    }

    // public entry fun remove_addred_nfts(
    //     sender: &signer
    // ) acquires NFTs{
    //     assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
    //
    //     let nfts = borrow_global_mut<NFTs>(resource_account::get_address());
    //     for (i in 0..vector::length(&nfts.nft_v1_vector)){
    //         let nft = vector::pop_back(&mut nfts.nft_v1_vector);
    //         let token_id = tokenv1::create_token_id_raw(
    //             nft.token_creator,
    //             nft.token_collection,
    //             nft.token_name,
    //             nft.token_property_version
    //         );
    //         let token = tokenv1::withdraw_token(&resource_account::get_signer(), token_id, 1);
    //         tokenv1::deposit_token(sender, token);
    //     };
    //
    //     for (i in 0..vector::length(&nfts.nft_v2_vector)){
    //         let nft = vector::pop_back(&mut nfts.nft_v2_vector);
    //         let nft_object = object::address_to_object<TokenV2>(nft.token_v2);
    //         object::transfer(&resource_account::get_signer(), nft_object, signer::address_of(sender));
    //     };
    // }


    #[randomness]
    entry fun play_multiple<CoinType>(
        sender: &signer,
        no_of_spins: u64
    ) acquires GameConfig, UserRewards, UserCoinRewards, NFTs{

        for (i in 0..no_of_spins){
            play<CoinType>(sender);
        }
    }

    #[randomness]
    entry fun play<CoinType>(
        sender: &signer
        // no_of_spins: u64
    ) acquires GameConfig, UserRewards, UserCoinRewards, NFTs{
        assert!(check_status<CoinType>(), E_ERROR_LOTTERY_PAUSED);
        process_fee<CoinType>(sender);

        let random_num = randomness::u64_range(0,10000);
        let tier = allot_tier(random_num);
        handle_tier<CoinType>(sender, tier);
    }

    entry fun claim<W,X,Y,Z>(sender: &signer, num_coins: u64)
    acquires UserRewards, UserCoinRewards, GameConfig {

        if (num_coins > 0) {
            assert!(check_status<W>(), E_ERROR_LOTTERY_PAUSED);
            let user_coin_rewards = borrow_global_mut<UserCoinRewards<W>>(signer::address_of(sender));
            let coins = coin::extract_all(&mut user_coin_rewards.coin);
            coin::deposit(signer::address_of(sender), coins);
        };

        if (num_coins > 1) {
            assert!(check_status<X>(), E_ERROR_LOTTERY_PAUSED);
            let user_coin_rewards = borrow_global_mut<UserCoinRewards<X>>(signer::address_of(sender));
            let coins = coin::extract_all(&mut user_coin_rewards.coin);
            coin::deposit(signer::address_of(sender), coins);
        };

        if (num_coins > 2) {
            assert!(check_status<Y>(), E_ERROR_LOTTERY_PAUSED);
            let user_coin_rewards = borrow_global_mut<UserCoinRewards<Y>>(signer::address_of(sender));
            let coins = coin::extract_all(&mut user_coin_rewards.coin);
            coin::deposit(signer::address_of(sender), coins);
        };

        if (num_coins > 3) {
            assert!(check_status<Z>(), E_ERROR_LOTTERY_PAUSED);
            let user_coin_rewards = borrow_global_mut<UserCoinRewards<Z>>(signer::address_of(sender));
            let coins = coin::extract_all(&mut user_coin_rewards.coin);
            coin::deposit(signer::address_of(sender), coins);
        };

        let sender_address = signer::address_of(sender);
        if (exists<UserRewards>(sender_address)) {
            let user_rewards = borrow_global_mut<UserRewards>(sender_address);

            for (i in 0..vector::length(&user_rewards.nft_v1)) {
                let nft_details = vector::pop_back(&mut user_rewards.nft_v1);

                let token_id = tokenv1::create_token_id_raw(
                    nft_details.token_creator,
                    nft_details.token_collection,
                    nft_details.token_name,
                    nft_details.token_property_version
                );
                let token = tokenv1::withdraw_token(&resource_account::get_signer(), token_id, 1);
                tokenv1::deposit_token(sender, token);
            };

            for (i in 0..vector::length(&user_rewards.nft_v2)) {
                let nft_details = vector::pop_back(&mut user_rewards.nft_v2);
                let nft_object = object::address_to_object<TokenV2>(nft_details.token_v2);
                object::transfer(&resource_account::get_signer(), nft_object, signer::address_of(sender));
            };

            // Claim raffle tickets if any
            let amount = user_rewards.raffle_ticket;
            if (amount > 0) {
                raffle::mint_ticket(&resource_account::get_signer(), sender_address, amount);
                user_rewards.raffle_ticket = 0;
            };

            if (user_rewards.waitlist_coins > 0) {
                emit_defy_coins_claim_event(sender_address, user_rewards.waitlist_coins);
                user_rewards.waitlist_coins = 0;
            }
        }
    }


    fun process_fee<CoinType>(sender: &signer) acquires GameConfig{
        let game_config = borrow_global<GameConfig<CoinType>>(resource_account::get_address());
        let fees = coin::withdraw<CoinType>(sender, game_config.spin_fee);
        house_treasury::merge_coins<CoinType>(fees);
    }



    // TIERS      | 10000  | 0-10000    |
    // #################################|
    // 1x NFT     | 200    | 0-200      |
    // 5M GUI     | 10     | 200-210    |
    // 1M GUI     | 90     | 210-300    |
    // 200k GUI   | 750    | 300-1050   |
    // 70k GUI    | 1570   | 1050-2620  |
    // 10k DEFY   | 250    | 2620-2870  |
    // 7.5k DEFY  | 280    | 2870-3150  |
    // 2.5k DEFY  | 1300   | 3150-4450  |
    // 1k DEFY    | 2000   | 4450-6450  |
    // 10 TICKETS | 250    | 6450-6700  |
    // 7 TICKETS  | 1300   | 6700-8000  |
    // 4 TICKETS  | 2000   | 8000-10000 |


    fun handle_tier<CoinType>(
        sender: &signer,
        tier: u64
    ) acquires  UserRewards, UserCoinRewards, NFTs, GameConfig {

        if(!exists<UserRewards>(signer::address_of(sender))){
            move_to<UserRewards>(sender, UserRewards{
                nft_v1: vector::empty<NFT_V1>(),
                nft_v2: vector::empty<NFT_V2>(),
                raffle_ticket: 0,
                waitlist_coins: 0,
            });
        };

        if(!exists<UserCoinRewards<CoinType>>(signer::address_of(sender))){
            move_to<UserCoinRewards<CoinType>>(sender, UserCoinRewards<CoinType>{
                coin: coin::zero<CoinType>(),
            });
        };

        let user_rewards = borrow_global_mut<UserRewards>(signer::address_of(sender));
        let user_coin_rewards = borrow_global_mut<UserCoinRewards<CoinType>>(signer::address_of(sender));
        let game_config = borrow_global_mut<GameConfig<CoinType>>(resource_account::get_address());
        if (tier == 0) {
            let nfts = borrow_global_mut<NFTs>(resource_account::get_address());

            if (vector::length(&nfts.nft_v2_vector) > 0){
                let nft_v2 = vector::pop_back(&mut nfts.nft_v2_vector);
                let reward_string = nft_v2.token_name;
                string::append(&mut reward_string, string::utf8(b"-"));
                string::append(&mut reward_string, nft_v2.image_url);
                vector::push_back(&mut user_rewards.nft_v2, nft_v2);
                emit_play_event(signer::address_of(sender), tier, reward_string, 1);
            }else if(vector::length(&nfts.nft_v1_vector) > 0){
                let nft_v1 = vector::pop_back(&mut nfts.nft_v1_vector);
                let reward_string = nft_v1.token_name;
                string::append(&mut reward_string, string::utf8(b"-"));
                string::append(&mut reward_string, nft_v1.image_url);
                vector::push_back(&mut user_rewards.nft_v1, nft_v1);
                emit_play_event(signer::address_of(sender), tier, reward_string, 1);

            } else{
                abort E_NO_NFTS_LEFT_IN_CONTRACT
            }
        } else if (tier == 1) {
            let coin_tier_value = *vector::borrow(&game_config.coin_reward_tiers_amounts, 0);
            let coins = house_treasury::extract_coins<CoinType>(coin_tier_value);
            coin::merge(&mut user_coin_rewards.coin, coins);
            emit_play_event(signer::address_of(sender), tier, type_info::type_name<CoinType>(), coin_tier_value);
        } else if (tier == 2) {
            let coin_tier_value = *vector::borrow(&game_config.coin_reward_tiers_amounts, 1);
            let coins = house_treasury::extract_coins<CoinType>(coin_tier_value);
            coin::merge(&mut user_coin_rewards.coin, coins);
            emit_play_event(signer::address_of(sender), tier, type_info::type_name<CoinType>(), coin_tier_value);
        } else if (tier == 3) {
            let coin_tier_value = *vector::borrow(&game_config.coin_reward_tiers_amounts, 2);
            let coins = house_treasury::extract_coins<CoinType>(coin_tier_value);
            coin::merge(&mut user_coin_rewards.coin, coins);
            emit_play_event(signer::address_of(sender), tier, type_info::type_name<CoinType>(), coin_tier_value);
        } else if (tier == 4) {
            let coin_tier_value = *vector::borrow(&game_config.coin_reward_tiers_amounts, 3);
            let coins = house_treasury::extract_coins<CoinType>(coin_tier_value);
            coin::merge(&mut user_coin_rewards.coin, coins);
            emit_play_event(signer::address_of(sender), tier, type_info::type_name<CoinType>(), coin_tier_value);
        } else if (tier == 5) {
            user_rewards.waitlist_coins = user_rewards.waitlist_coins + 10000;
            emit_play_event(signer::address_of(sender), tier, string::utf8(b"Waitlist Coins"), 10000);
        } else if (tier == 6) {
            user_rewards.waitlist_coins = user_rewards.waitlist_coins + 7500;
            emit_play_event(signer::address_of(sender), tier, string::utf8(b"Waitlist Coins"), 7500);
        } else if (tier == 7) {
            user_rewards.waitlist_coins = user_rewards.waitlist_coins + 2500;
            emit_play_event(signer::address_of(sender), tier, string::utf8(b"Waitlist Coins"), 2500);
        } else if (tier == 8) {
            user_rewards.waitlist_coins = user_rewards.waitlist_coins + 1000;
            emit_play_event(signer::address_of(sender), tier, string::utf8(b"Waitlist Coins"), 1000);
        } else if (tier == 9) {
            user_rewards.raffle_ticket = user_rewards.raffle_ticket + 10;
            emit_play_event(signer::address_of(sender), tier, string::utf8(b"Raffle Ticket"), 10);
        } else if (tier == 10) {
            user_rewards.raffle_ticket = user_rewards.raffle_ticket + 7;
            emit_play_event(signer::address_of(sender), tier, string::utf8(b"Raffle Ticket"), 7);
        } else if (tier == 11) {
            user_rewards.raffle_ticket = user_rewards.raffle_ticket + 4;
            emit_play_event(signer::address_of(sender), tier, string::utf8(b"Raffle Ticket"), 4);
        } else {
            abort E_REWARD_TIER_OUT_OF_BOUNDS
        };
    }



    // TIERS      | 10000  | 0-10000   |
    // ################################|
    // 1x NFT     | 200    | 0-200     |
    // 5M GUI     | 10     | 200-210   |
    // 1M GUI     | 90     | 210-300   |
    // 200k GUI   | 750    | 300-1050  |
    // 70k GUI    | 1570   | 1050-2620 |
    // 10k DEFY   | 250    | 2620-2870 |
    // 7.5k DEFY  | 280    | 2870-3150 |
    // 2.5k DEFY  | 1300   | 3150-4450 |
    // 1k DEFY    | 2000   | 4450-6450 |
    // 10 TICKETS | 250    | 6450-6700 |
    // 7 TICKETS  | 1300   | 6700-8000 |
    // 4 TICKETS  | 2000   | 8000-10000 |

    fun allot_tier(random_num: u64): u64 {
        if (random_num < 200) {
            0
        } else if (random_num < 210) {
            1
        } else if (random_num < 300) {
            2
        } else if (random_num < 1050) {
            3
        } else if (random_num <  2620) {
            4
        } else if (random_num < 2870) {
            5
        } else if (random_num < 3150) {
            6
        } else if (random_num < 4450) {
            7
        } else if (random_num < 6450) {
            8
        } else if (random_num < 6700) {
            9
        } else if (random_num < 8000) {
            10
        } else if (random_num < 10000) {
            11
        } else {
            abort E_RANDOM_NUM_OUT_OF_BOUNDS
        }
    }

    fun check_status<CoinType>(): bool acquires GameConfig {
        borrow_global<GameConfig<CoinType>>(resource_account::get_address()).active
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

    fun emit_play_event(player: address, reward_tier: u64, reward_type: String, reward_amount: u64) {
        0x1::event::emit(PlayEvent {
            player,
            reward_tier,
            reward_type,
            reward_amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    fun emit_defy_coins_claim_event(player: address, amount: u64) {
        0x1::event::emit(DefyCoinsClaimEvent {
            player,
            amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    #[view]
    public fun see_resource_address(): address {
        resource_account::get_address()
    }


}