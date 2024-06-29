module mini_games::plinko {
    use std::signer;
    use std::vector;
    use std::string::{String};

    use aptos_framework::aptos_account;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::type_info;
    use aptos_framework::randomness;

    use mini_games::resource_account_manager as resource_account;
    use mini_games::house_treasury;

    /// you are not authorized to call this function
    const E_ERROR_UNAUTHORIZED: u64 = 1;
    /// the game for the coin type does not exist
    const E_GAME_FOR_COIN_TYPE_DOES_NOT_EXIST: u64 = 2;
    /// the game is paused
    const E_GAME_PAUSED: u64 = 3;
    /// the coin type is invalid
    const E_ERROR_INVALID_COIN: u64 = 4;
    /// the game for the coin type already exists
    const E_GAME_FOR_COIN_TYPE_DOES_ALREADY_EXIST: u64 = 5;
    /// Treasury for this coin does not exist in the casino
    const E_ERROR_TREASURY_DOES_NOT_EXIST_FOR_THIS_COIN: u64 = 6;
    /// Treasury for this coin is not active
    const E_ERROR_TREASURY_NOT_ACTIVE_FOR_THIS_COIN: u64 = 7;
    /// the balls amount is too high
    const E_ERROR_BALLS_AMOUNT_TOO_HIGH: u64 = 8;
    /// the balls amount is too low
    const E_ERROR_BALLS_AMOUNT_TOO_LOW: u64 = 9;
    /// the bet amount is too high
    const E_ERROR_BET_AMOUNT_TOO_HIGH: u64 = 10;
    /// the bet amount is too low
    const E_ERROR_BET_AMOUNT_TOO_LOW: u64 = 11;
    /// the number of pin lines cannot be zero
    const E_ERROR_NUM_PIN_LINES_CANNOT_BE_ZERO: u64 = 12;
    /// the number of pin lines and the length of the multiplier vector are not compatible
    const E_ERROR_INVALID_NUM_PIN_LINES_OR_VECTOR_LEN: u64 = 13;



    struct GameConfig has key {
        max_balls_per_play: u64,
        min_balls_per_play: u64,
        multiplier_divisor: u64,
        multiplier_vector: vector<u64>,
        pin_lines: u64,
    }

    struct GameManager<phantom CoinType> has key {
        active: bool,
        max_bet_amount: u64,
        min_bet_amount: u64,
        counter: u64,
        defy_coins_exchange_rate: u64,
    }

    struct PlayerRewards<phantom CoinType> has key {
        rewards_balance : Coin<CoinType>,
        num_plays: u64
    }

    struct PlayerDefyCoinRewards has key {
        rewards_balance : u64,
    }

    #[event]
    struct PlayEvent has drop, store {
        player : address,
        coin_type: String,
        bet_amount: u64,
        ball_path: vector<u16>,
        multiplier: u64,
        amount_won: u64,
        defy_coins_won: u64
    }

    #[event]
    struct DefyCoinsClaimEvent has drop, store {
        player: address,
        amount: u64,
    }

    // Default values for the game config :
    // max_balls_per_play: 10,
    // min_balls_per_play: 1,
    // multiplier_divisor: 100,
    // multiplier_vector: vector[1000, 600, 400, 200, 100, 60, 30, 60, 100, 200, 400, 600, 1000],
    // pin_lines: 12

    // public entry fun add_or_update_game_config(
    public entry fun add_game_config(
        sender: &signer,
        max_balls_per_play: u64,
        min_balls_per_play: u64,
        multiplier_divisor: u64,
        multiplier_vector: vector<u64>,
        pin_lines: u64
    ) {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        move_to(&resource_account::get_signer(), GameConfig{
            max_balls_per_play,
            min_balls_per_play,
            multiplier_divisor,
            multiplier_vector,
            pin_lines
        });
    }


    public entry fun add_new_game<CoinType>(
        sender: &signer,
        max_bet_amount: u64,
        min_bet_amount: u64,
        // 1 defy coin == defy_coins_exchange_rate CoinType
        defy_coins_exchange_rate: u64
    ) {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        assert!(!exists<GameManager<CoinType>>(resource_account::get_address()), E_GAME_FOR_COIN_TYPE_DOES_ALREADY_EXIST);
        assert!(house_treasury::does_treasury_exist<CoinType>(), E_ERROR_TREASURY_DOES_NOT_EXIST_FOR_THIS_COIN);
        move_to(&resource_account::get_signer(), GameManager<CoinType> {
            active: true,
            max_bet_amount,
            min_bet_amount,
            counter: 0,
            defy_coins_exchange_rate
        });
    }

    public entry fun pause_game<CoinType>(
        sender: &signer
    ) acquires GameManager {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let game_manager = borrow_global_mut<GameManager<CoinType>>(resource_account::get_address());
        game_manager.active = false;
    }

    public entry fun resume_game<CoinType>(
        sender: &signer
    ) acquires GameManager {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let game_manager = borrow_global_mut<GameManager<CoinType>>(resource_account::get_address());
        game_manager.active = true;
    }


    public entry fun set_max_and_min_bet_amount<CoinType>(
        sender: &signer,
        max_bet_amount: u64,
        min_bet_amount: u64
    ) acquires GameManager {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let game_manager = borrow_global_mut<GameManager<CoinType>>(resource_account::get_address());
        game_manager.max_bet_amount = max_bet_amount;
        game_manager.min_bet_amount = min_bet_amount;
    }

    public entry fun set_defy_coin_exchange_value<CoinType>(
        sender: &signer,
        defy_coins_exchange_rate: u64
    ) acquires GameManager {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let game_manager = borrow_global_mut<GameManager<CoinType>>(resource_account::get_address());
        game_manager.defy_coins_exchange_rate = defy_coins_exchange_rate;
    }

    public entry fun set_max_balls_per_play<CoinType>(
        sender: &signer,
        max_balls_per_play: u64
    ) acquires GameConfig {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let game_config = borrow_global_mut<GameConfig>(resource_account::get_address());
        game_config.max_balls_per_play = max_balls_per_play;
    }

    public entry fun set_min_balls_per_play<CoinType>(
        sender: &signer,
        min_balls_per_play: u64
    ) acquires GameConfig {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let game_config = borrow_global_mut<GameConfig>(resource_account::get_address());
        game_config.min_balls_per_play = min_balls_per_play;
    }

    // public entry fun set_multiplier_divisor<CoinType>(
    //     sender: &signer,
    //     multiplier_divisor: u64
    // ) acquires GameConfig {
    //     assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
    //     let game_config = borrow_global_mut<GameConfig>(resource_account::get_address());
    //     game_config.multiplier_divisor = multiplier_divisor;
    // }

    public entry fun set_pin_lines_and_multiplier_vector<CoinType>(
        sender: &signer,
        pin_lines: u64,
        multiplier_vector: vector<u64>,
        multiplier_divisor: u64
    ) acquires GameConfig {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        assert!(pin_lines > 0 , E_ERROR_NUM_PIN_LINES_CANNOT_BE_ZERO);
        let game_config = borrow_global_mut<GameConfig>(resource_account::get_address());
        let vec_len = vector::length(&multiplier_vector);
        let pins_in_last_line = pin_lines +2;
        assert!(vec_len == pins_in_last_line-1, E_ERROR_INVALID_NUM_PIN_LINES_OR_VECTOR_LEN);
        game_config.pin_lines = pin_lines;
        game_config.multiplier_vector = multiplier_vector;
        game_config.multiplier_divisor = multiplier_divisor;
    }




    #[randomness]
    entry fun play<CoinType>(
        sender: &signer,
        bet_amount: u64,
        num_balls: u64,
    ) acquires GameManager, PlayerRewards, GameConfig , PlayerDefyCoinRewards{
        assert!(house_treasury::is_treasury_active<CoinType>(), E_ERROR_TREASURY_NOT_ACTIVE_FOR_THIS_COIN);
        assert!(exists<GameManager<CoinType>>(resource_account::get_address()), E_GAME_FOR_COIN_TYPE_DOES_NOT_EXIST);
        assert!(exists<GameConfig>(resource_account::get_address()), E_GAME_FOR_COIN_TYPE_DOES_NOT_EXIST);

        let game_manager = borrow_global_mut<GameManager<CoinType>>(resource_account::get_address());
        let game_config = borrow_global<GameConfig>(resource_account::get_address());

        assert!(game_manager.active, E_GAME_PAUSED);
        assert!(bet_amount <= game_manager.max_bet_amount, E_ERROR_BET_AMOUNT_TOO_HIGH);
        assert!(bet_amount >= game_manager.min_bet_amount, E_ERROR_BET_AMOUNT_TOO_LOW);
        assert!(num_balls <= game_config.max_balls_per_play, E_ERROR_BALLS_AMOUNT_TOO_HIGH);
        assert!(num_balls >= game_config.min_balls_per_play, E_ERROR_BALLS_AMOUNT_TOO_LOW);

        let total_bet  = bet_amount * num_balls;
        let bet_coins = coin::withdraw<CoinType>(sender, total_bet);
        house_treasury::merge_coins(bet_coins);

        let plinko_path_hashes  = generate_all_paths_hashes(num_balls);

        for( i in 0..num_balls ){
            handle_drop<CoinType>(sender, bet_amount, *vector::borrow<vector<u8>>(&plinko_path_hashes, i));
        };
    }

    entry fun claim<X, Y, Z, A, B>(sender: &signer, num_coins : u64)
    acquires PlayerRewards , PlayerDefyCoinRewards{

        if (num_coins >= 1){
            assert!(exists<PlayerRewards<X>>(signer::address_of(sender)), E_ERROR_INVALID_COIN);
            let player_rewards = borrow_global_mut<PlayerRewards<X>>(signer::address_of(sender));
            let reward_coins = &mut player_rewards.rewards_balance;
            let value = coin::value(reward_coins);
            let coins = coin::extract(reward_coins, value);
            aptos_account::deposit_coins(signer::address_of(sender), coins);
        };

        if (num_coins  >= 2){
            assert!(exists<PlayerRewards<Y>>(signer::address_of(sender)), E_ERROR_INVALID_COIN);
            let player_rewards = borrow_global_mut<PlayerRewards<Y>>(signer::address_of(sender));
            let reward_coins = &mut player_rewards.rewards_balance;
            let value = coin::value(reward_coins);
            let coins = coin::extract(reward_coins, value);
            aptos_account::deposit_coins(signer::address_of(sender), coins);
        };

        if (num_coins >= 3){
            assert!(exists<PlayerRewards<Z>>(signer::address_of(sender)), E_ERROR_INVALID_COIN);
            let player_rewards = borrow_global_mut<PlayerRewards<Z>>(signer::address_of(sender));
            let reward_coins = &mut player_rewards.rewards_balance;
            let value = coin::value(reward_coins);
            let coins = coin::extract(reward_coins, value);
            aptos_account::deposit_coins(signer::address_of(sender), coins);
        };

        if (num_coins >= 4){
            assert!(exists<PlayerRewards<A>>(signer::address_of(sender)), E_ERROR_INVALID_COIN);
            let player_rewards = borrow_global_mut<PlayerRewards<A>>(signer::address_of(sender));
            let reward_coins = &mut player_rewards.rewards_balance;
            let value = coin::value(reward_coins);
            let coins = coin::extract(reward_coins, value);
            aptos_account::deposit_coins(signer::address_of(sender), coins);
        };

        if (num_coins >= 5){

            assert!(exists<PlayerRewards<B>>(signer::address_of(sender)), E_ERROR_INVALID_COIN);
            let player_rewards = borrow_global_mut<PlayerRewards<B>>(signer::address_of(sender));
            let reward_coins = &mut player_rewards.rewards_balance;
            let value = coin::value(reward_coins);
            let coins = coin::extract(reward_coins, value);
            aptos_account::deposit_coins(signer::address_of(sender), coins);
        };

        if(exists<PlayerDefyCoinRewards>(signer::address_of(sender))){
            let player_defy_coin_rewards = borrow_global_mut<PlayerDefyCoinRewards>(signer::address_of(sender));
            let value = player_defy_coin_rewards.rewards_balance;
            if (value > 0){
                player_defy_coin_rewards.rewards_balance = 0;
                emit_defy_coins_claim_event(signer::address_of(sender), value);
            };
        };
    }

    // commented as this wont run on contract upgrade
    // fun init_module(_sender: &signer) {
    //     move_to(&resource_account::get_signer(), GameConfig{
    //         max_balls_per_play: 10,
    //         min_balls_per_play: 1,
    //         multiplier_divisor: 100,
    //         multiplier_vector: vector[500, 400, 300, 200, 100, 80, 40, 80, 100, 200, 300, 400, 500],
    //         pin_lines: 12
    //     });
    // }

    fun generate_all_paths_hashes(num_balls: u64): vector<vector<u8>> {
        let paths_hashes = vector::empty<vector<u8>>();
        for (i in 0..num_balls) {
            vector::push_back(&mut paths_hashes, randomness::bytes(32));
        };

        paths_hashes
    }



    fun handle_drop<CoinType>(
        sender: &signer,
        bet_amount: u64,
        path_hash: vector<u8>
    ) acquires GameManager, PlayerRewards, GameConfig, PlayerDefyCoinRewards {

        if(!exists<PlayerRewards<CoinType>>(signer::address_of(sender))){
            move_to(sender, PlayerRewards<CoinType> {
                rewards_balance: coin::zero<CoinType>(),
                num_plays: 0
            });
        };

        if(!exists<PlayerDefyCoinRewards>(signer::address_of(sender))){
            move_to(sender, PlayerDefyCoinRewards {
                rewards_balance: 0
            });
        };

        let game_manager = borrow_global_mut<GameManager<CoinType>>(resource_account::get_address());
        let defy_coins_exchange_rate = game_manager.defy_coins_exchange_rate;
        let game_config = borrow_global<GameConfig>(resource_account::get_address());
        let player_rewards = borrow_global_mut<PlayerRewards<CoinType>>(signer::address_of(sender));
        let player_defy_coin_rewards = borrow_global_mut<PlayerDefyCoinRewards>(signer::address_of(sender));
        player_rewards.num_plays = player_rewards.num_plays + 1;

        let ball_path = vector::empty<u16>();
        let multiplier_index = 0;
        for (i in 0..game_config.pin_lines){
            let byte = *vector::borrow<u8>(&path_hash, i);
            let step = if (byte % 2 == 0) {
                0
            } else {
                1
            };
            multiplier_index = multiplier_index + step;
            vector::push_back(&mut ball_path, step);
        };
        let multiplier = *(vector::borrow<u64>(&game_config.multiplier_vector, (multiplier_index as u64)));
        let amount_won = (bet_amount * multiplier ) / game_config.multiplier_divisor;
        let defy_coins_won = if (amount_won < bet_amount){
            (bet_amount - amount_won) / defy_coins_exchange_rate
        } else {
            0
        };
        player_defy_coin_rewards.rewards_balance = player_defy_coin_rewards.rewards_balance + defy_coins_won;
        let coins = house_treasury::extract_coins<CoinType>(amount_won);
        coin::merge(&mut player_rewards.rewards_balance, coins);
        emit_play_event(signer::address_of(sender), type_info::type_name<CoinType>(), amount_won, bet_amount, ball_path, multiplier, defy_coins_won);

    }

    fun bytes_to_u64(bytes: vector<u8>): u64 {
        let value    = 0u64;
        let i = 0u64;
        while (i < 8) {
            value = value | ((*vector::borrow(&bytes, i) as u64) << ((8 * (7 - i)) as u8));
            i = i + 1;
        };
        return value
    }


    fun emit_play_event(player: address, coin_type: String, amount_won: u64, bet_amount: u64, ball_path: vector<u16>, multiplier: u64, defy_coins_won: u64) {

        0x1::event::emit(PlayEvent {
            player,
            coin_type,
            bet_amount,
            ball_path,
            multiplier,
            amount_won,
            defy_coins_won
        });
    }

    fun emit_defy_coins_claim_event(player: address, amount: u64) {
        0x1::event::emit(DefyCoinsClaimEvent {
            player,
            amount
        });
    }

    #[view]
    public fun see_resource_address(): address {
        resource_account::get_address()
    }



}