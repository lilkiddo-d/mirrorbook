// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Robinhood Chain mainnet (4663) addresses. Mirrors config/chains.ts — see that file for sources.
library RobinhoodConfig {
    uint256 internal constant CHAIN_ID = 4663;

    // https://docs.robinhood.com/chain/contracts
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    // https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood
    address internal constant USDG_USD_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;

    // https://developers.uniswap.org/docs/protocols/v3/deployments/v3-robinhood-chain-deployments
    address internal constant UNI_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;

    uint32 internal constant STOCK_MAX_STALENESS = 90_000; // 24h heartbeat + 1h buffer
    uint32 internal constant USDG_MAX_STALENESS = 90_000;
    uint16 internal constant STOCK_MAX_ROUND_DEVIATION_BPS = 2_500;
    uint16 internal constant USDG_MAX_ROUND_DEVIATION_BPS = 200;

    struct Stock {
        string symbol;
        address token; // https://api.robinhood.com/rhj/assets (chainId 4663)
        address feed; // Chainlink "Robinhood <SYM> / USD"
    }

    function stocks() internal pure returns (Stock[] memory s) {
        s = new Stock[](11);
        s[0] = Stock("AAPL", 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9, 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0);
        s[1] = Stock("NVDA", 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15);
        s[2] = Stock("TSLA", 0x322F0929c4625eD5bAd873c95208D54E1c003b2d, 0x4A1166a659A55625345e9515b32adECea5547C38);
        s[3] = Stock("MSFT", 0xe93237C50D904957Cf27E7B1133b510C669c2e74, 0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E);
        s[4] = Stock("AMZN", 0x12f190a9F9d7D37a250758b26824B97CE941bF54, 0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C);
        s[5] = Stock("GOOGL", 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, 0xF6f373a037c30F0e5010d854385cA89185AE638b);
        s[6] = Stock("META", 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35, 0x7C38C00C30BEe9378381E7B6135d7283356D71b1);
        s[7] = Stock("AMD", 0x86923f96303D656E4aa86D9d42D1e57ad2023fdC, 0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72);
        s[8] = Stock("COIN", 0x6330D8C3178a418788dF01a47479c0ce7CCF450b, 0xA3a468A452940B7D6b69991207B508c609a98Ef2);
        s[9] = Stock("SPY", 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C, 0x319724394D3A0e3669269846abE664Cd621f9f6A);
        s[10] = Stock("QQQ", 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68, 0x80901d846d5D7B030F26B480776EE3b29374C2ae);
    }
}
