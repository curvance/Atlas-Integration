// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "lib/atlas/test/base/BaseTest.t.sol";
import "@atlas/contracts/libraries/CallVerification.sol";
import "@atlas/contracts/types/UserOperation.sol";
import "@atlas/contracts/types/SolverOperation.sol";
import "@atlas/contracts/types/DAppOperation.sol";
import "@atlas/contracts/types/AtlasErrors.sol";
import {SolverBase} from "@atlas/contracts/solver/SolverBase.sol";

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IMarketManager} from "contracts/interfaces/IMarketManager.sol";
import { AuctionManager } from "src/AuctionManager.sol";
import { ChainlinkWrapperEntrypoint } from "src/ChainlinkWrapperEntrypoint.sol";
import { ChainlinkCurvanceOEVWrapper } from "src/ChainlinkCurvanceOEVWrapper.sol";

import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { console2 } from "forge-std/console2.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD_SQUARED, WAD_SQUARED_BPS_OFFSET, BPS, WAD } from "contracts/libraries/ConstantsLib.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import {AtlasEvents} from "@atlas/contracts/types/AtlasEvents.sol";
import {SolverOutcome} from "@atlas/contracts/types/EscrowTypes.sol";
import {Vm} from "forge-std/Vm.sol";

// Mock Aggregator V3 Interface
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function latestRound() external view returns (uint256);
}

// Mock Chainlink Feed for testing
contract MockChainlinkFeed is AggregatorV3Interface {
    uint8 public override decimals = 8;
    string public override description = "Mock ETH/USD Feed";
    uint256 public override version = 1;

    uint80 private _latestRoundId = 100;
    int256 private _latestAnswer = 2000e8; // $2000
    uint256 private _latestTimestamp = block.timestamp;

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_latestRoundId, _latestAnswer, _latestTimestamp, _latestTimestamp, _latestRoundId);
    }

    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _latestAnswer, _latestTimestamp, _latestTimestamp, _roundId);
    }

    function latestRound() external view override returns (uint256) {
        return _latestRoundId;
    }

    // Helper function to update the mock feed
    function setLatestAnswer(int256 newAnswer) external {
        _latestAnswer = newAnswer;
        _latestRoundId++;
        _latestTimestamp = block.timestamp;
    }
}

contract AuctionManagerSolverScenariosTest is BaseTest, AtlasErrors, TestBaseMarketIsolated {
    MarketManagerIsolated public unauthorizedMarketManager;
    AuctionManager public auctionManager_;
    ChainlinkWrapperEntrypoint public wrapperEntrypoint;
    ChainlinkCurvanceOEVWrapper public wrapper1;
    ChainlinkCurvanceOEVWrapper public wrapper2;
    MockChainlinkFeed public mockFeed1;
    MockChainlinkFeed public mockFeed2;

    address public unlistedToken = address(0xccccccc); // Unlisted collateral token for testing

    MockSolver public solver;
    MockSolver public solver2;
    MockSolver public solver3;

    address public constant OEV_ALLOCATION_DESTINATION_FASTLANE = address(0x4111);
    address public constant OEV_ALLOCATION_DESTINATION_PROTOCOL = address(0x5111);
    uint256 public constant OEV_SHARE_BUNDLER = 2000; // 20%
    uint256 public constant OEV_SHARE_FASTLANE = 1000; // 10%
    uint32 public constant SOLVER_GAS_LIMIT = 6_000_000;
    uint256 solverBidAmount = 1 ether;
    uint256 solverOpTestPenalty = 10100;

    uint256 auctioneerPK = 0xabcdef;
    address auctioneer = vm.addr(auctioneerPK);

    uint256 userOpSignerPK = 0xDEADBEEF123456789ABCDEF;
    address userOpSigner = vm.addr(userOpSignerPK);

    uint256 bundlerPK = 0x234567;
    address bundler = vm.addr(bundlerPK);

    address mockCurvanceGov = address(0xf11);

    function setUp() public override(BaseTest, TestBaseMarketIsolated) {
        // Initialize Curvance test harness
        TestBaseMarketIsolated.setUp();

        // Initialize Atlas harness
        __createAndLabelAccounts();
        __deployAtlasContracts();
        __fundSolversAndDepositAtlETH();

        vm.startPrank(centralRegistry.daoAddress());
        _prepareDAI(centralRegistry.daoAddress(), 77777 * 2);
        _prepareUSDC(centralRegistry.daoAddress(), 77777 * 2);
        dai.approve(address(borrowableCDAI), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);
        marketManagerIsolated.listTokens(address(borrowableCDAI), address(borrowableCUSDC));
        _setCTokenConfigBasic(address(borrowableCDAI), 1_000_000e18, 1_000_000e18);
        _setCTokenConfigBasic(address(borrowableCUSDC), 1_000_000e6, 1_000_000e6);
        vm.stopPrank();

        vm.startPrank(governanceEOA);
        auctionManager_ = new AuctionManager(
            address(atlas),
            OEV_SHARE_FASTLANE,
            OEV_ALLOCATION_DESTINATION_FASTLANE,
            OEV_ALLOCATION_DESTINATION_PROTOCOL
        );

        auctionManager_.setCentralRegistry(ICentralRegistry(address(centralRegistry)));
        auctionManager_.setAuthorizedUserOpSigner(userOpSigner);
        atlasVerification.initializeGovernance(address(auctionManager_));
        atlasVerification.addSignatory(address(auctionManager_), auctioneer);
        vm.stopPrank();

        address executionEnv = auctionManager_.authorizedExecutionEnv();
        vm.startPrank(centralRegistry.emergencyCouncil());
        centralRegistry.addAuctionPermissions(executionEnv);
        centralRegistry.addAuctionPermissions(address(auctionManager_));
        vm.stopPrank();

        // check permissions are set
        bool hasExecEnvPerms = centralRegistry.hasAuctionPermissions(executionEnv);
        bool hasControlPerms = centralRegistry.hasAuctionPermissions(address(auctionManager_));
        assertTrue(hasExecEnvPerms, "execution env perms not set");
        assertTrue(hasControlPerms, "control perms not set");

        // Deploy mock Chainlink feeds and real wrappers
        mockFeed1 = new MockChainlinkFeed();
        mockFeed2 = new MockChainlinkFeed();

        wrapper1 = new ChainlinkCurvanceOEVWrapper(
            address(mockFeed1),
            governanceEOA,
            3, // maxDecrements
            10 // maxRoundDelay
        );

        wrapper2 = new ChainlinkCurvanceOEVWrapper(
            address(mockFeed2),
            governanceEOA,
            3, // maxDecrements
            10 // maxRoundDelay
        );

        // Deploy the wrapper entrypoint
        wrapperEntrypoint = new ChainlinkWrapperEntrypoint(governanceEOA);

        vm.startPrank(governanceEOA);

        // Configure wrappers in the entrypoint
        wrapperEntrypoint.configureWrapper(address(wrapper1), true);
        wrapperEntrypoint.configureWrapper(address(wrapper2), true);

        // Whitelist the wrapper entrypoint as an oracle
        auctionManager_.addAllowedRoute(address(wrapperEntrypoint), ChainlinkWrapperEntrypoint.batchUpdatePriceEarly.selector);

        // Whitelist the entrypoint in both wrappers
        wrapper1.setWhitelist(address(wrapperEntrypoint), true);
        wrapper2.setWhitelist(address(wrapperEntrypoint), true);

        vm.stopPrank();

        // MockSolver now needs all contract addresses passed to constructor
        vm.prank(solverOneEOA);
        solver = new MockSolver(
            address(WETH_ADDRESS),
            address(atlas),
            address(borrowableCUSDC),
            address(borrowableCDAI),
            address(usdc),
            address(dai),
            address(marketManagerIsolated),
            address(oracleManager),
            user1
        );
        vm.deal(address(solver), 10 * solverBidAmount);
        vm.prank(solverOneEOA);
        atlas.depositAndBond{value: 5 ether}(5 ether);

        // Give solver USDC for liquidation
        _prepareUSDC(address(solver), 1000e6);

        // Set up additional solvers with same parameters (each targets different user)
        vm.prank(solverTwoEOA);
        solver2 = new MockSolver(
            address(WETH_ADDRESS),
            address(atlas),
            address(borrowableCUSDC),
            address(borrowableCDAI),
            address(usdc),
            address(dai),
            address(marketManagerIsolated),
            address(oracleManager),
            user2
        );
        vm.deal(address(solver2), 10 * solverBidAmount);
        vm.prank(solverTwoEOA);
        atlas.depositAndBond{value: 5 ether}(5 ether);
        _prepareUSDC(address(solver2), 1000e6);

        vm.prank(solverThreeEOA);
        solver3 = new MockSolver(
            address(WETH_ADDRESS),
            address(atlas),
            address(borrowableCUSDC),
            address(borrowableCDAI),
            address(usdc),
            address(dai),
            address(marketManagerIsolated),
            address(oracleManager),
            user3
        );
        vm.deal(address(solver3), 10 * solverBidAmount);
        vm.prank(solverThreeEOA);
        atlas.depositAndBond{value: 5 ether}(5 ether);
        _prepareUSDC(address(solver3), 1000e6);

        // ========================================
        // Liquidation setup - add user1 with DAI collateral and USDC debt
        // ========================================
        vm.startPrank(centralRegistry.daoAddress());

        // Market setup
        _prepareDAI(centralRegistry.daoAddress(), 77777);
        _prepareUSDC(centralRegistry.daoAddress(), 100_000e6 + 77777);

        // Token approvals
        usdc.approve(address(borrowableCUSDC), 100_000e18 + 77777);
        dai.approve(address(borrowableCDAI), 77777);

        // Deposit USDC
        borrowableCUSDC.deposit(100_000e6, centralRegistry.daoAddress());

        // Set initial prices
        mockUsdcFeed.setMockAnswer(1e8);
        mockDaiFeed.setMockAnswer(1e8);

        vm.stopPrank();

        // Set up user1 position
        vm.startPrank(user1);
        _prepareDAI(user1, 1000e18);
        dai.approve(address(borrowableCDAI), 1000e18);
        borrowableCDAI.depositAsCollateral(1000e18, user1);
        borrowableCUSDC.borrow(500e6, user1);
        vm.stopPrank();

        // Set up user2 position (same as user1)
        vm.startPrank(user2);
        _prepareDAI(user2, 1000e18);
        dai.approve(address(borrowableCDAI), 1000e18);
        borrowableCDAI.depositAsCollateral(1000e18, user2);
        borrowableCUSDC.borrow(500e6, user2);
        vm.stopPrank();

        // Set up user3 position (same as user1)
        vm.startPrank(user3);
        _prepareDAI(user3, 1000e18);
        dai.approve(address(borrowableCDAI), 1000e18);
        borrowableCDAI.depositAsCollateral(1000e18, user3);
        borrowableCUSDC.borrow(500e6, user3);
        vm.stopPrank();

        // Drop DAI price to make all users liquidatable with auction buffer
        mockDaiFeed.setMockAnswer(70007000);

        // Create unauthorized market manager (not registered in central registry)
        vm.prank(centralRegistry.daoAddress());
        unauthorizedMarketManager = new MarketManagerIsolated(
            ICentralRegistry(address(centralRegistry)),
            10e18, // minLoanSize
            true // isCorrelatedMarket
        );
    }

    // Initialization test
    // function testInitialization() public view {
    //     assertEq(auctionManager_.fastlaneRevenueDestination(), OEV_ALLOCATION_DESTINATION_FASTLANE);
    //     assertEq(auctionManager_.curvanceRevenueDestination(), OEV_ALLOCATION_DESTINATION_PROTOCOL);
    //     assertEq(auctionManager_.fastlaneSplitBPS(), OEV_SHARE_FASTLANE);
    //     assertEq(auctionManager_.solverGasLimit(), SOLVER_GAS_LIMIT);
    //     assertEq(auctionManager_.authorizedUserOpSigner(), userOpSigner);
    //     assertEq(address(auctionManager_.CENTRAL_REGISTRY()), address(centralRegistry));
    // }

    function buildUserOperation(uint256 signerPK) internal view returns (UserOperation memory) {
        // Encode the batch update call with the entrypoint's batchUpdatePriceEarly
        bytes memory updateCallData = abi.encodeWithSelector(ChainlinkWrapperEntrypoint.batchUpdatePriceEarly.selector);

        address signer = vm.addr(signerPK);
        UserOperation memory userOp = UserOperation({
            from: signer,
            to: address(atlas),
            value: 0,
            gas: 1_000_000,
            maxFeePerGas: 1_000_000_000,
            nonce: 1,
            deadline: block.number + 100,
            dapp: address(auctionManager_),
            control: address(auctionManager_),
            callConfig: auctionManager_.CALL_CONFIG(),
            dappGasLimit: 2_000_000,
            solverGasLimit: SOLVER_GAS_LIMIT,
            bundlerSurchargeRate: 1000,
            sessionKey: auctioneer,
            data: abi.encodeWithSelector(
                auctionManager_.update.selector,
                address(wrapperEntrypoint),
                updateCallData
            ),
            signature: new bytes(0)
        });

        Sig memory sig;
        (sig.v, sig.r, sig.s) = vm.sign(signerPK, atlasVerification.getUserOperationPayload(userOp));
        userOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
        return userOp;
    }

    function buildSolverOperation(
        uint256 solverPK,
        address solverContract,
        bytes32 userOpHash,
        uint256 bidAmount,
        address collateral,
        address market,
        bool isReverting
    ) internal view returns (SolverOperation memory) {
        bytes memory data;
        if (isReverting) {
            data = abi.encodeWithSelector(solver.solveRevert.selector, collateral, market);
        } else {
            data = abi.encodeWithSelector(solver.solve.selector, collateral, market);
        }

        address solverEoa = vm.addr(solverPK);
        SolverOperation memory solverOp = SolverOperation({
            from: solverEoa,
            to: address(atlas),
            value: 0,
            gas: SOLVER_GAS_LIMIT,
            maxFeePerGas: 1_000_000_000,
            deadline: block.number + 100,
            solver: solverContract,
            control: address(auctionManager_),
            userOpHash: userOpHash,
            bidToken: address(0),
            bidAmount: bidAmount,
            data: data,
            signature: new bytes(0)
        });

        Sig memory sig;
        (sig.v, sig.r, sig.s) = vm.sign(solverPK, atlasVerification.getSolverPayload(solverOp));
        solverOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
        return solverOp;
    }

    function buildDAppOperation(bytes32 userOpHash, bytes32 callChainHash, address givenBundler)
        internal
        view
        returns (DAppOperation memory)
    {
        DAppOperation memory dappOp = DAppOperation({
            from: auctioneer,
            to: address(atlas),
            nonce: 0,
            deadline: block.number + 100,
            control: address(auctionManager_),
            bundler: givenBundler,
            userOpHash: userOpHash,
            callChainHash: callChainHash,
            signature: new bytes(0)
        });
        Sig memory sig;
        (sig.v, sig.r, sig.s) = vm.sign(auctioneerPK, atlasVerification.getDAppOperationPayload(dappOp));
        dappOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
        return dappOp;
    }

    struct SolverBidPattern {
        uint256 bidAmount;
        uint256 testPenalty;
        address collateral;
        address market;
        bool isPreSolverOpFailing;
        bool isReverting;
    }

    function threeSolverTestTemplate(
        SolverBidPattern memory solverOne,
        SolverBidPattern memory solverTwo,
        SolverBidPattern memory solverThree
    ) public {
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);
        address executionEnv = auctionManager_.authorizedExecutionEnv();

        bytes32 userOpHash = atlasVerification.getUserOperationHash(userOp);
        SolverOperation memory solverOp1 = buildSolverOperation(
            solverOnePK,
            address(solver),
            userOpHash,
            solverOne.bidAmount,
            solverOne.collateral,
            solverOne.market,
            solverOne.isReverting
        );
        SolverOperation memory solverOp2 = buildSolverOperation(
            solverTwoPK,
            address(solver2),
            userOpHash,
            solverTwo.bidAmount,
            solverTwo.collateral,
            solverTwo.market,
            solverTwo.isReverting
        );
        SolverOperation memory solverOp3 = buildSolverOperation(
            solverThreePK,
            address(solver3),
            userOpHash,
            solverThree.bidAmount,
            solverThree.collateral,
            solverThree.market,
            solverThree.isReverting
        );
        SolverOperation[] memory solverOps = new SolverOperation[](3);
        solverOps[0] = solverOp1;
        solverOps[1] = solverOp2;
        solverOps[2] = solverOp3;
        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp = buildDAppOperation(userOpHash, callChainHash, bundler);

        uint256 fastlaneBalanceBefore = address(OEV_ALLOCATION_DESTINATION_FASTLANE).balance;
        uint256 protocolBalanceBefore = address(OEV_ALLOCATION_DESTINATION_PROTOCOL).balance;

        uint256 solverOneBidPaid = solverOne.isReverting || solverOne.isPreSolverOpFailing ? 0 : solverOne.bidAmount;
        uint256 solverTwoBidPaid = solverTwo.isReverting || solverTwo.isPreSolverOpFailing ? 0 : solverTwo.bidAmount;
        uint256 solverThreeBidPaid =
            solverThree.isReverting || solverThree.isPreSolverOpFailing ? 0 : solverThree.bidAmount;

        uint256 solverOneResult = solverOne.isPreSolverOpFailing
            ? (1 << uint256(SolverOutcome.PreSolverFailed))
            : (solverOne.isReverting ? (1 << uint256(SolverOutcome.SolverOpReverted)) : 0);
        uint256 solverTwoResult = solverTwo.isPreSolverOpFailing
            ? (1 << uint256(SolverOutcome.PreSolverFailed))
            : (solverTwo.isReverting ? (1 << uint256(SolverOutcome.SolverOpReverted)) : 0);
        uint256 solverThreeResult = solverThree.isPreSolverOpFailing
            ? (1 << uint256(SolverOutcome.PreSolverFailed))
            : (solverThree.isReverting ? (1 << uint256(SolverOutcome.SolverOpReverted)) : 0);

        uint256 solverOneBondedBefore = atlas.balanceOfBonded(address(solverOneEOA));
        uint256 solverTwoBondedBefore = atlas.balanceOfBonded(address(solverTwoEOA));
        uint256 solverThreeBondedBefore = atlas.balanceOfBonded(address(solverThreeEOA));

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        uint256 bundlerBalanceBefore = address(bundler).balance;
        uint256 auctionManagerBalanceBefore = address(auctionManager_).balance;

        // Track solver collateral balances before metacall
        uint256 solver1CollBefore = borrowableCDAI.balanceOf(address(solver));
        uint256 solver2CollBefore = borrowableCDAI.balanceOf(address(solver2));
        uint256 solver3CollBefore = borrowableCDAI.balanceOf(address(solver3));

        // Track user debt balances and lFactors before metacall (needed for expected collateral calculation)
        // All liquidation state must be captured BEFORE metacall since user positions change after liquidation
        uint256 user1DebtBefore = borrowableCUSDC.debtBalanceUpdated(user1);
        uint256 user2DebtBefore = borrowableCUSDC.debtBalanceUpdated(user2);
        uint256 user3DebtBefore = borrowableCUSDC.debtBalanceUpdated(user3);

        (, , , uint256 user1LFactorBefore) = _liquidationValuesOfHelper(marketManagerIsolated, user1);
        (, , , uint256 user2LFactorBefore) = _liquidationValuesOfHelper(marketManagerIsolated, user2);
        (, , , uint256 user3LFactorBefore) = _liquidationValuesOfHelper(marketManagerIsolated, user3);

        // ============================================
        // PART 1: WITHOUT AUCTION - Should FAIL
        // ============================================
        // Try to liquidate WITHOUT auction setup (no unlock, no transient config)
        // All users are barely healthy (within auction buffer zone)

        address[] memory borrowersToLiquidate = new address[](1);

        // Test user1 liquidation without auction - should fail
        borrowersToLiquidate[0] = user1;
        vm.prank(solverOneEOA);
        vm.expectRevert(abi.encodeWithSignature("MarketManager__NoLiquidationAvailable()"));
        solver.callLiquidateDirectly(
            address(borrowableCUSDC),
            borrowersToLiquidate,
            address(borrowableCDAI)
        );

        // Test user2 liquidation without auction - should fail
        borrowersToLiquidate[0] = user2;
        vm.prank(solverTwoEOA);
        vm.expectRevert(abi.encodeWithSignature("MarketManager__NoLiquidationAvailable()"));
        solver2.callLiquidateDirectly(
            address(borrowableCUSDC),
            borrowersToLiquidate,
            address(borrowableCDAI)
        );

        // Test user3 liquidation without auction - should fail
        borrowersToLiquidate[0] = user3;
        vm.prank(solverThreeEOA);
        vm.expectRevert(abi.encodeWithSignature("MarketManager__NoLiquidationAvailable()"));
        solver3.callLiquidateDirectly(
            address(borrowableCUSDC),
            borrowersToLiquidate,
            address(borrowableCDAI)
        );

        // ============================================
        // PART 2: WITH AUCTION - Should SUCCEED
        // ============================================
        // Now execute via Atlas auction (which applies auction buffer)

        // Expect the oracle update to happen successfully (before solver execution)
        vm.expectEmit(true, false, false, true, address(wrapperEntrypoint));
        emit ChainlinkWrapperEntrypoint.BatchUpdateExecuted(
            address(auctionManager_), // updater is the dapp control
            2, // totalWrappers
            2  // successfulUpdates
        );

        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver),
            solverOneEOA,
            address(auctionManager_),
            address(0),
            solverOne.bidAmount,
            !solverOne.isPreSolverOpFailing,
            !solverOne.isReverting && !solverOne.isPreSolverOpFailing,
            solverOneResult
        );
        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver2),
            solverTwoEOA,
            address(auctionManager_),
            address(0),
            solverTwo.bidAmount,
            !solverTwo.isPreSolverOpFailing,
            !solverTwo.isReverting && !solverTwo.isPreSolverOpFailing,
            solverTwoResult
        );
        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver3),
            solverThreeEOA,
            address(auctionManager_),
            address(0),
            solverThree.bidAmount,
            !solverThree.isPreSolverOpFailing,
            !solverThree.isReverting && !solverThree.isPreSolverOpFailing,
            solverThreeResult
        );
        if (solverOneBidPaid + solverTwoBidPaid + solverThreeBidPaid > 0) {
            uint256 totalOev = solverOneBidPaid + solverTwoBidPaid + solverThreeBidPaid;
            // Expect revenue to be allocated to AuctionManager
            vm.expectEmit(true, false, false, true, address(auctionManager_));
            emit AuctionManager.RevenueAllocated(totalOev);
        }
        // Expect MetacallResult - only checking indexed params (bundler, user), not gas values
        vm.expectEmit(true, true, false, false, address(atlas));
        emit AtlasEvents.MetacallResult(
            bundler,
            userOpSigner,
            false, // solverSuccessful = false (always false in this DApp config, not a failure)
            0, // ethPaidToBundler
            0 // netGasSurcharge
        );

        vm.recordLogs();

        vm.startBroadcast(bundlerPK);

        (bool success, bytes memory returnData) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        // Retrieve and decode logs.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool eventFound = false;
        uint256 ethPaidToBundler;
        uint256 netGasSurcharge;
        for (uint256 i = 0; i < logs.length; i++) {
            // Check for the correct event signature.
            if (
                logs[i].topics.length >= 3
                    && logs[i].topics[0] == keccak256("MetacallResult(address,address,bool,uint256,uint256)")
            ) {
                eventFound = true;
                (, uint256 _ethPaidToBundler, uint256 _netGasSurcharge) =
                    abi.decode(logs[i].data, (bool, uint256, uint256));

                ethPaidToBundler = _ethPaidToBundler;
                netGasSurcharge = _netGasSurcharge;
                require(ethPaidToBundler > 0, "ethPaidToBundler is not > 0");
                require(netGasSurcharge > 0, "netGasSurcharge is not > 0");
            }
        }

        assertEq(success, true, "metacall should succeed");

        bool auctionWon = abi.decode(returnData, (bool));
        assertEq(auctionWon, false, "auctionWon = false (DApp config), but revenue is allocated");

        assertLt(atlas.balanceOfBonded(address(solverOneEOA)), solverOneBondedBefore);
        assertLt(atlas.balanceOfBonded(address(solverTwoEOA)), solverTwoBondedBefore);
        assertLt(atlas.balanceOfBonded(address(solverThreeEOA)), solverThreeBondedBefore);

        // Verify each solver received exact amount of seized collateral (only for successful solvers)
        if (!solverOne.isReverting && !solverOne.isPreSolverOpFailing) {
            uint256 solver1CollAfter = borrowableCDAI.balanceOf(address(solver));

            // Calculate expected debt repaid and liquidation incentive for user1 using pre-captured values
            (uint256 liqIncBase, uint256 liqIncCurve, , , uint256 closeFactorBase, uint256 closeFactorCurve,,) =
                marketManagerIsolated.liquidationConfig(address(borrowableCDAI));
            uint256 expectedCloseFactor = closeFactorBase + ((closeFactorCurve * user1LFactorBefore) / 1e18);
            uint256 expectedMaxDebtRepaid = (user1DebtBefore * expectedCloseFactor) / 10000;
            uint256 expectedLiqIncentive = liqIncBase + ((liqIncCurve * user1LFactorBefore) / 1e18);

            uint256 expectedCollateral = _calculateExpectedCollateralSeized(
                expectedMaxDebtRepaid,
                expectedLiqIncentive,
                address(borrowableCDAI),
                address(borrowableCUSDC)
            );

            assertEq(
                solver1CollAfter - solver1CollBefore,
                expectedCollateral,
                "solver1 collateral increase doesn't match expected seized amount"
            );
        }
        if (!solverTwo.isReverting && !solverTwo.isPreSolverOpFailing) {
            uint256 solver2CollAfter = borrowableCDAI.balanceOf(address(solver2));

            // Calculate expected debt repaid and liquidation incentive for user2 using pre-captured values
            (uint256 liqIncBase, uint256 liqIncCurve, , , uint256 closeFactorBase, uint256 closeFactorCurve,,) =
                marketManagerIsolated.liquidationConfig(address(borrowableCDAI));
            uint256 expectedCloseFactor = closeFactorBase + ((closeFactorCurve * user2LFactorBefore) / 1e18);
            uint256 expectedMaxDebtRepaid = (user2DebtBefore * expectedCloseFactor) / 10000;
            uint256 expectedLiqIncentive = liqIncBase + ((liqIncCurve * user2LFactorBefore) / 1e18);

            uint256 expectedCollateral = _calculateExpectedCollateralSeized(
                expectedMaxDebtRepaid,
                expectedLiqIncentive,
                address(borrowableCDAI),
                address(borrowableCUSDC)
            );

            assertEq(
                solver2CollAfter - solver2CollBefore,
                expectedCollateral,
                "solver2 collateral increase doesn't match expected seized amount"
            );
        }
        if (!solverThree.isReverting && !solverThree.isPreSolverOpFailing) {
            uint256 solver3CollAfter = borrowableCDAI.balanceOf(address(solver3));

            // Calculate expected debt repaid and liquidation incentive for user3 using pre-captured values
            (uint256 liqIncBase, uint256 liqIncCurve, , , uint256 closeFactorBase, uint256 closeFactorCurve,,) =
                marketManagerIsolated.liquidationConfig(address(borrowableCDAI));
            uint256 expectedCloseFactor = closeFactorBase + ((closeFactorCurve * user3LFactorBefore) / 1e18);
            uint256 expectedMaxDebtRepaid = (user3DebtBefore * expectedCloseFactor) / 10000;
            uint256 expectedLiqIncentive = liqIncBase + ((liqIncCurve * user3LFactorBefore) / 1e18);

            uint256 expectedCollateral = _calculateExpectedCollateralSeized(
                expectedMaxDebtRepaid,
                expectedLiqIncentive,
                address(borrowableCDAI),
                address(borrowableCUSDC)
            );

            assertEq(
                solver3CollAfter - solver3CollBefore,
                expectedCollateral,
                "solver3 collateral increase doesn't match expected seized amount"
            );
        }

        // Verify AuctionManager balance increased by sum of all successful solver bids
        uint256 totalBidsPaid = solverOneBidPaid + solverTwoBidPaid + solverThreeBidPaid;
        uint256 auctionManagerBalanceAfter = address(auctionManager_).balance;
        assertEq(
            auctionManagerBalanceAfter,
            auctionManagerBalanceBefore + totalBidsPaid,
            "AuctionManager should have received sum of all solver bid amounts as revenue"
        );
    }

    function testOevAuction_multipleSolvers_oevBids_success() public {
        threeSolverTestTemplate(
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty,
                collateral: address(borrowableCDAI),
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: solverBidAmount * 2,
                testPenalty: solverOpTestPenalty,
                collateral: address(borrowableCDAI),
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: solverBidAmount * 3,
                testPenalty: solverOpTestPenalty,
                collateral: address(borrowableCDAI),
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            })
        );
    }

    // Helper function to calculate collateral seized based on debt repaid and liquidation incentive
    function _calculateExpectedCollateralSeized(
        uint256 debtRepaid,
        uint256 liqIncentive,
        address collateralToken,
        address debtToken
    ) internal returns (uint256) {
        // IDENTICAL: Get prices (reference file lines 184-185)
        (uint256 collateralTokenPrice, uint256 debtTokenPrice) =
            oracleManager.getPriceIsolatedPair(collateralToken, debtToken, 2);

        // IDENTICAL: Get decimals (reference file lines 188-189)
        uint256 collateralTokenDecimals = 10 ** borrowableCDAI.decimals();
        uint256 debtTokenDecimals = 10 ** borrowableCUSDC.decimals();

        // IDENTICAL: Calculate debtToCollateral (reference file lines 191-202)
        // debtToCollateral = (((liqInc * debtPrice * WAD_SQUARED_BPS_OFFSET) / collateralPrice) * collateralDecimals) / debtDecimals
        uint256 temp = FixedPointMathLib.mulDiv(
            FixedPointMathLib.mulDiv(liqIncentive, debtTokenPrice, 1),
            WAD_SQUARED_BPS_OFFSET,
            collateralTokenPrice
        );
        uint256 debtToCollateral = FixedPointMathLib.mulDiv(
            temp,
            collateralTokenDecimals,
            debtTokenDecimals
        );

        // IDENTICAL: Calculate expected collateral seized (reference file lines 205-209)
        return FixedPointMathLib.mulDiv(
            debtRepaid,
            debtToCollateral,
            WAD_SQUARED
        );
    }
}

// MockSolver with full Curvance liquidation implementation
contract MockSolver is SolverBase {
    fallback() external payable {}
    receive() external payable {}

    address[] borrowers;

    // Store necessary contract references
    BorrowableCToken public immutable borrowableCUSDC;
    BorrowableCToken public immutable borrowableCDAI;
    IERC20 public immutable usdc;
    IERC20 public immutable dai;
    MarketManagerIsolated public immutable marketManagerIsolated;
    IOracleManager public immutable oracleManager;

    constructor(
        address weth,
        address atlas,
        address _borrowableCUSDC,
        address _borrowableCDAI,
        address _usdc,
        address _dai,
        address _marketManagerIsolated,
        address _oracleManager,
        address _user1
    ) SolverBase(weth, atlas, msg.sender) {
        borrowableCUSDC = BorrowableCToken(_borrowableCUSDC);
        borrowableCDAI = BorrowableCToken(_borrowableCDAI);
        usdc = IERC20(_usdc);
        dai = IERC20(_dai);
        marketManagerIsolated = MarketManagerIsolated(_marketManagerIsolated);
        oracleManager = IOracleManager(_oracleManager);
        borrowers.push(_user1);
    }

    // Helper function to call liquidate directly without auction setup
    function callLiquidateDirectly(
        address debtToken,
        address[] calldata borrowersToliquidate,
        address collateralToken
    ) external {
        usdc.approve(debtToken, type(uint256).max);
        BorrowableCToken(debtToken).liquidate(borrowersToliquidate, collateralToken);
    }

    function solve(address collateral, address market) external {
        MarketManagerIsolated marketManager = MarketManagerIsolated(market);

        // Validate transient liquidation config was set correctly
        (address storedCollateral, uint256 storedIncentive, uint256 storedCloseFactor) =
            marketManager.getTransientLiquidationConfig();

        require(storedCollateral == collateral, "MockSolver: collateral mismatch");
        require(storedIncentive == 0, "Incentive should be stored as 0 to signal protocol-derived");
        require(storedCloseFactor == 0, "Close factor should be stored as 0 to signal protocol-derived");

        // Solver already has USDC from setUp(), just approve
        usdc.approve(address(borrowableCUSDC), 1000e6);

        address user1 = borrowers[0];

        // Get balances before liquidation
        uint256 debtBefore = borrowableCUSDC.debtBalanceUpdated(user1);
        uint256 collateralBefore = borrowableCDAI.balanceOf(user1);

        uint256 expectedMaxDebtRepaid;
        uint256 expectedCollateralSeized;
        {
            // Get protocol liquidation config
            (uint256 liqIncBase, uint256 liqIncCurve, , , uint256 closeFactorBase, uint256 closeFactorCurve,,)
                = marketManagerIsolated.liquidationConfig(address(borrowableCDAI));

            // Get lFactor for borrower
            (, , , uint256 lFactor) = _liquidationValuesOfHelper(marketManagerIsolated, user1);

            // VERIFY AUCTION BUFFER WAS APPLIED TO LFACTOR CALCULATION
            uint256 auctionBuffer = marketManagerIsolated.AUCTION_BUFFER();
            require(auctionBuffer == 9950, "Auction buffer must be 9950 (50bps)");

            // VERIFY CURVE VALUES ARE NON-ZERO (protocol-derived actually used curves)
            require(liqIncCurve > 0, "CURVANCE BUG: liqIncCurve is zero, protocol-derived won't work");
            require(closeFactorCurve > 0, "CURVANCE BUG: closeFactorCurve is zero, protocol-derived won't work");
            require(lFactor > 0, "CURVANCE BUG: lFactor is zero, user shouldn't be liquidatable");

            // Calculate expected close factor
            uint256 expectedCloseFactor = closeFactorBase + ((closeFactorCurve * lFactor) / 1e18);

            // Calculate expected liquidation incentive
            uint256 expectedLiqIncentive = liqIncBase + ((liqIncCurve * lFactor) / 1e18);

            // Calculate expected max debt repaid
            expectedMaxDebtRepaid = (debtBefore * expectedCloseFactor) / 10000;

            // Calculate expected collateral seized
            expectedCollateralSeized = _calculateExpectedCollateralSeized(
                expectedMaxDebtRepaid,
                expectedLiqIncentive,
                address(borrowableCDAI),
                address(borrowableCUSDC)
            );
        }

        // Execute liquidation
        borrowableCUSDC.liquidate(borrowers, address(borrowableCDAI));

        // Get balances after liquidation
        uint256 debtAfter = borrowableCUSDC.debtBalanceUpdated(user1);
        uint256 collateralAfter = borrowableCDAI.balanceOf(user1);

        uint256 debtRepaid = debtBefore - debtAfter;
        uint256 collateralSeized = collateralBefore - collateralAfter;

        // Verify debt repaid matches expected
        require(debtRepaid == expectedMaxDebtRepaid,
            "Debt repaid must exactly match expected value from protocol-derived close factor");

        // Verify collateral seized matches expected
        require(collateralSeized == expectedCollateralSeized,
            "Collateral seized must exactly match expected value from protocol-derived liquidation incentive");

        // Verify user is now healthy after liquidation
        (, uint256 maxDebtAfter, uint256 debtAfterLiq) = marketManagerIsolated.statusOf(user1);
        require(debtAfterLiq <= maxDebtAfter,
            "CURVANCE BUG: User must be healthy after liquidation");
    }

    function solveRevert(address collateral, address market) external pure {
        revert("Atlas OEV is not allowed");
    }

    // Helper function to calculate expected collateral seized
    function _calculateExpectedCollateralSeized(
        uint256 debtRepaid,
        uint256 liqIncentive,
        address collateralToken,
        address debtToken
    ) internal returns (uint256) {
        // Get prices
        (uint256 collateralTokenPrice, uint256 debtTokenPrice) =
            oracleManager.getPriceIsolatedPair(collateralToken, debtToken, 2);

        // Get decimals
        uint256 collateralTokenDecimals = 10 ** borrowableCDAI.decimals();
        uint256 debtTokenDecimals = 10 ** borrowableCUSDC.decimals();

        // Calculate debtToCollateral
        // debtToCollateral = (((liqInc * debtPrice * WAD_SQUARED_BPS_OFFSET) / collateralPrice) * collateralDecimals) / debtDecimals
        uint256 temp = FixedPointMathLib.mulDiv(
            FixedPointMathLib.mulDiv(liqIncentive, debtTokenPrice, 1),
            WAD_SQUARED_BPS_OFFSET,
            collateralTokenPrice
        );
        uint256 debtToCollateral = FixedPointMathLib.mulDiv(
            temp,
            collateralTokenDecimals,
            debtTokenDecimals
        );

        // Calculate expected collateral seized
        return FixedPointMathLib.mulDiv(
            debtRepaid,
            debtToCollateral,
            WAD_SQUARED
        );
    }

    // Helper function copied from TestBaseMarketIsolated to calculate lFactor
    function _liquidationValuesOfHelper(
        MarketManagerIsolated mm,
        address account
    ) internal returns (
        uint256 cSoft,
        uint256 cHard,
        uint256 debt,
        uint256 lFactor
    ) {
        address[] memory assets = mm.assetsOf(account);
        (AccountSnapshot[] memory snapshots, uint256[] memory prices, uint256 numAssets) =
            oracleManager.getPricesForMarket(account, assets, 2);

        for (uint256 i; i < numAssets; ++i) {
            AccountSnapshot memory snap = snapshots[i];

            if (snap.isCollateral) {
                (, uint256 collReqSoft, uint256 collReqHard) = mm.collConfig(snap.asset);
                uint256 assetValue = FixedPointMathLib.mulDiv(
                    snap.collateralPosted,
                    prices[i],
                    10 ** snap.decimals
                ) * BPS;

                cSoft += assetValue / collReqSoft;
                cHard += assetValue / collReqHard;
            } else {
                if (snap.debtBalance > 0) {
                    debt += FixedPointMathLib.mulDivUp(
                        snap.debtBalance,
                        prices[i],
                        10 ** snap.decimals
                    );
                }
            }
        }

        uint256 auctionBuffer = mm.AUCTION_BUFFER();
        if (auctionBuffer != 0) {
            cSoft = FixedPointMathLib.mulDiv(cSoft, auctionBuffer, BPS);
            cHard = FixedPointMathLib.mulDiv(cHard, auctionBuffer, BPS);
        }

        if (cSoft >= debt) {
            lFactor = 0;
        } else if (debt >= cHard) {
            lFactor = WAD;
        } else {
            lFactor = FixedPointMathLib.mulDivUp(debt - cSoft, WAD, cHard - cSoft);
        }
    }
}

// Mock solver that attempts liquidation with different collateral than solver data
contract MockSolverWithCollateralMismatch is SolverBase, TestBaseMarketIsolated {
    fallback() external payable {}
    receive() external payable {}

    MarketManagerIsolated public marketManager;
    address public wrongCollateralToLiquidate; // Different from what's in solver data

    constructor(
        address weth,
        address atlas,
        MarketManagerIsolated _marketManager,
        address _wrongCollateralToLiquidate
    ) SolverBase(weth, atlas, msg.sender) {
        marketManagerIsolated = _marketManager;
        wrongCollateralToLiquidate = _wrongCollateralToLiquidate;
    }

    function solve(address collateral, address market) external {
        // Validate transient liquidation config was set correctly by preSolverCall
        (address storedCollateral, uint256 storedIncentive, uint256 storedCloseFactor) =
            marketManagerIsolated.getTransientLiquidationConfig();

        require(storedCollateral == collateral, "MockSolverWithCollateralMismatch: collateral mismatch in config");
        require(storedIncentive == 0, "MockSolverWithCollateralMismatch: incentive should be 0");
        require(storedCloseFactor == 0, "MockSolverWithCollateralMismatch: closeFactor should be 0");

        // The solver data has 'collateral' (which got unlocked in preSolverCall)
        // But we'll try to liquidate 'wrongCollateralToLiquidate' instead
        // This should trigger the _UNAUTHORIZED_LIQUIDATION_SELECTOR in _checkLiquidationConfig

        // First set up a position for liquidation

        mockDaiFeed.setMockAnswer(1e8);
        mockUsdcFeed.setMockAnswer(1e8);

        _prepareDAI(address(this), 77777 + 1_000_000e18);
        _prepareUSDC(address(this), 77777);
        dai.approve(address(borrowableCDAI), 77777 + 1_000_000e18);
        usdc.approve(address(borrowableCUSDC), 77777);
        marketManagerIsolated.listTokens(address(borrowableCDAI), address(borrowableCUSDC));
        _setCTokenConfigBasic(address(borrowableCDAI), 1_000_000e18, 1_000_000e18);
        _setCTokenConfigBasic(address(borrowableCUSDC), 1_000_000e6, 1_000_000e6);

        borrowableCDAI.deposit(1_000_000e18, address(this));

        vm.startPrank(user1);
        _prepareUSDC(user1, 500e6);
        usdc.approve(address(borrowableCUSDC),500e6);
        borrowableCUSDC.depositAsCollateral(500e6, user1);
        borrowableCDAI.borrow(100e18, user1);

        mockDaiFeed.setMockAnswer(1e7);

        address[] memory borrowers;
        borrowers[0] = user1;

        // Now attempt liquidation with the WRONG collateral (not what was unlocked)
        borrowableCDAI.liquidate(
            borrowers,
            wrongCollateralToLiquidate
        );

    }

    function solveRevert(address collateral, address market) external pure {
        revert("Atlas OEV is not allowed");
    }
}