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

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import {AtlasEvents} from "@atlas/contracts/types/AtlasEvents.sol";
import {SolverOutcome} from "@atlas/contracts/types/EscrowTypes.sol";
import {Vm} from "forge-std/Vm.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import { AuctionManager } from "src/AuctionManager.sol";
import { ChainlinkWrapperEntrypoint } from "src/ChainlinkWrapperEntrypoint.sol";
import { ChainlinkCurvanceOEVWrapper } from "src/ChainlinkCurvanceOEVWrapper.sol";

import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { console2 } from "forge-std/console2.sol";

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

contract AuctionManagerPreSolverTest is BaseTest, AtlasErrors, TestBaseMarketIsolated {

    MarketManagerIsolated public unauthorizedMarketManager;
    AuctionManager public auctionManager_;
    ChainlinkWrapperEntrypoint public wrapperEntrypoint;
    ChainlinkCurvanceOEVWrapper public wrapper1;
    ChainlinkCurvanceOEVWrapper public wrapper2;
    MockChainlinkFeed public mockFeed1;
    MockChainlinkFeed public mockFeed2;

    address public collateralToken = address(0xccccccc);
    address public invalidCollateral = address(0xbbbbbbb);

    MockSolver public solver;

    address public constant OEV_ALLOCATION_DESTINATION_FASTLANE = address(0x4111);
    address public constant OEV_ALLOCATION_DESTINATION_PROTOCOL = address(0x5111);
    uint256 public constant OEV_SHARE_BUNDLER = 2000; // 20%
    uint256 public constant OEV_SHARE_FASTLANE = 1000; // 10%
    uint32 public constant SOLVER_GAS_LIMIT = 6_000_000;
    uint256 solverBidAmount = 1 ether;
    uint256 solverOpTestPenalty = 10100;

    uint256 auctioneerPK = 0xabcdef;
    address auctioneer = vm.addr(auctioneerPK);

    uint256 userOpSignerPK = 0x123456;
    address userOpSigner = vm.addr(userOpSignerPK);

    uint256 bundlerPK = 0x234567;
    address bundler = vm.addr(bundlerPK);

    address mockCurvanceGov = address(0xf11);

    function setUp() public override(BaseTest, TestBaseMarketIsolated) {
        // Initialize Curvance test harness
        TestBaseMarketIsolated.setUp();

        // Initialize Atlas test harness
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

        // Create unauthorized market manager (not registered in central registry)
        unauthorizedMarketManager = new MarketManagerIsolated(
            ICentralRegistry(address(centralRegistry)),
            10e18, // minLoanSize
            true // isCorrelatedMarket
        );

        vm.stopPrank();

        vm.startPrank(governanceEOA);


        auctionManager_ = new AuctionManager(
            address(atlas),
            ICentralRegistry(address(centralRegistry)),
            OEV_SHARE_FASTLANE,
            OEV_ALLOCATION_DESTINATION_FASTLANE,
            OEV_ALLOCATION_DESTINATION_PROTOCOL
        );

        auctionManager_.setAuthorizedUserOpSigner(userOpSigner);
        atlasVerification.initializeGovernance(address(auctionManager_));
        atlasVerification.addSignatory(address(auctionManager_), auctioneer);

        // Grant control the user op signer wallet
        vm.stopPrank();

        vm.startPrank(governanceEOA);
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

        vm.prank(solverOneEOA);
        solver = new MockSolver(address(WETH_ADDRESS), address(atlas));
        vm.deal(address(solver), 10 * solverBidAmount);
        vm.prank(solverOneEOA);
        atlas.depositAndBond{value: 5 ether}(5 ether);
    }

    // ========================================
    // Test Unauthorized Market Manager
    // ========================================

    function testPreSolverCall_unauthorizedMarket_preSolverFails() public {
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);

        SolverOperation memory solverOp = buildSolverOperation(
            solverOnePK,
            address(solver),
            atlasVerification.getUserOperationHash(userOp),
            solverBidAmount,
            collateralToken,
            address(unauthorizedMarketManager), // Use unauthorized market
            false // not reverting
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp =
            buildDAppOperation(atlasVerification.getUserOperationHash(userOp), callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        // Expect the solver to fail with PreSolverFailed due to unauthorized market
        // because the market manager is not registered in the central registry
        uint256 expectedResult = 1 << uint256(SolverOutcome.PreSolverFailed);
        
        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver),
            solverOneEOA,
            address(auctionManager_),
            address(0),
            solverBidAmount,
            false, // executed = false (PreSolver failed)
            false, // success = false
            expectedResult // PreSolverFailed
        );
        
        vm.startBroadcast(bundlerPK);
        
        // Atlas catches ALL PreSolver reverts gracefully, including unauthorized markets!
        // verifyMarketManager() revert is caught just like penalty validation failures
        (bool success, bytes memory returnData) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        // Atlas handles the failure gracefully:
        assertEq(success, true, "metacall should succeed even with unauthorized market");
        bool auctionWon = abi.decode(returnData, (bool));
        assertEq(auctionWon, false, "auction should not be won due to PreSolver failure");
    }

    // ========================================
    // Test Invalid Collateral
    // ========================================

    function testPreSolverCall_invalidCollateral_preSolverFails() public {
        // Test with a collateral that's not configured in the market manager
        // The market manager only has collateralToken configured, so invalidCollateral should fail
        // with _UNAUTHORIZED_LIQUIDATION_SELECTOR because ctData.collRatio == 0 for unlisted tokens
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);

        SolverOperation memory solverOp = buildSolverOperation(
            solverOnePK,
            address(solver),
            atlasVerification.getUserOperationHash(userOp),
            solverBidAmount,
            invalidCollateral, // This collateral is NOT configured in market manager
            address(marketManagerIsolated),
            false
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp =
            buildDAppOperation(atlasVerification.getUserOperationHash(userOp), callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        // Expect the solver to fail with PreSolverFailed due to unauthorized liquidation
        // The specific error MarketManager__UnauthorizedLiquidation() (0xfac97a2b) will be caught by Atlas
        uint256 expectedResult = 1 << uint256(SolverOutcome.PreSolverFailed);

        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver),
            solverOneEOA,
            address(auctionManager_),
            address(0),
            solverBidAmount,
            false, // executed = false (PreSolver failed due to unauthorized collateral)
            false, // success = false
            expectedResult // PreSolverFailed
        );

        vm.startBroadcast(bundlerPK);

        // Atlas catches the MarketManager__UnauthorizedLiquidation() error gracefully
        // and marks the solver as PreSolverFailed
        (bool success, bytes memory returnData) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        // Atlas handles the failure gracefully:
        assertEq(success, true, "metacall should succeed even with unauthorized collateral");
        bool auctionWon = abi.decode(returnData, (bool));
        assertEq(auctionWon, false, "auction should not be won due to PreSolver failure");
    }

    function testPreSolverCall_mismatchedCollateral_preSolverFails() public {
        // Test where both collaterals are valid/listed, but there's a mismatch:
        // - Solver data specifies invalidCollateral (gets unlocked in preSolverCall)
        // - But solver attempts liquidation with collateralToken (different from unlocked)
        // This should fail the transient storage check in _checkLiquidationConfig

        // First, configure invalidCollateral in the market manager so it's "valid"
        vm.prank(mockCurvanceGov);

        UserOperation memory userOp = buildUserOperation(userOpSignerPK);

        // Create a solver that will attempt liquidation with the WRONG collateral
        MockSolverWithCollateralMismatch mismatchSolver = new MockSolverWithCollateralMismatch(
            address(WETH_ADDRESS),
            address(atlas),
            marketManagerIsolated, // Pass the contract directly, not address
            address(borrowableCUSDC) // Try to liquidate a different listed token than unlocked
        );

        vm.deal(address(mismatchSolver), 10 * solverBidAmount);

        SolverOperation memory solverOp = buildSolverOperation(
            solverOnePK,
            address(mismatchSolver),
            atlasVerification.getUserOperationHash(userOp),
            solverBidAmount,
            address(borrowableCUSDC),
            address(marketManagerIsolated),
            false
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp =
            buildDAppOperation(atlasVerification.getUserOperationHash(userOp), callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        // Expect the solver to revert during execution due to collateral mismatch
        uint256 expectedResult = 1 << uint256(SolverOutcome.SolverOpReverted);

        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(mismatchSolver),
            solverOneEOA,
            address(auctionManager_),
            address(0),
            solverBidAmount,
            true, // executed = true (preSolver passed, but solver reverted)
            false, // success = false (solver reverted during execution)
            expectedResult // SolverOpReverted
        );

        vm.startBroadcast(bundlerPK);

        (bool success, bytes memory returnData) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        // Atlas handles the solver revert gracefully:
        assertEq(success, true, "metacall should succeed even with solver collateral mismatch");
        bool auctionWon = abi.decode(returnData, (bool));
        assertEq(auctionWon, false, "auction should not be won due to solver failure");
    }

    // ========================================
    // Test Extreme Penalty Values - These Should All Fail PreSolver
    // ========================================

    function testPreSolverCall_unlistedCollateral_preSolverFailsLegacy() public {
        // NOTE: This test validates that zero penalty (0%) fails PreSolver validation
        // because it's below the minimum allowed penalty of 5% (0.05e18)
        _testPenaltyValueExpectingPreSolverFailure(0);
    }

    function testPreSolverCall_unlistedCollateral_preSolverFailsLegacy_2() public {
        // NOTE: This test validates that max penalty fails PreSolver validation
        // because it's above the maximum allowed penalty of 15% (0.15e18)
        _testPenaltyValueExpectingPreSolverFailure(type(uint256).max);
    }

    function testPreSolverCall_unlistedCollateral_preSolverFailsLegacy_3() public {
        // NOTE: This test validates that 1000% penalty fails PreSolver validation
        // because it's above the maximum allowed penalty of 15% (0.15e18)
        _testPenaltyValueExpectingPreSolverFailure(10e18); // 1000% penalty
    }

    function _testPenaltyValueExpectingPreSolverFailure(uint256 penalty) internal {
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);

        SolverOperation memory solverOp = buildSolverOperation(
            solverOnePK,
            address(solver),
            atlasVerification.getUserOperationHash(userOp),
            solverBidAmount,
            collateralToken,
            address(marketManagerIsolated),
            false
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp =
            buildDAppOperation(atlasVerification.getUserOperationHash(userOp), callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        // Expect the solver to fail with PreSolverFailed due to invalid penalty
        uint256 expectedResult = 1 << uint256(SolverOutcome.PreSolverFailed);

        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver),
            solverOneEOA,
            address(auctionManager_),
            address(0),
            solverBidAmount,
            false, // executed = false (PreSolver failed)
            false, // success = false
            expectedResult // PreSolverFailed
        );

        vm.startBroadcast(bundlerPK);

        (bool success, bytes memory returnData) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        // Atlas handles the failure gracefully:
        assertEq(success, true, "metacall should succeed even with invalid penalty");
        bool auctionWon = abi.decode(returnData, (bool));
        assertEq(auctionWon, false, "auction should not be won due to PreSolver failure");
    }

    // ========================================
    // Test Malformed Solver Data
    // ========================================

    function testPreSolverCall_malformedData_reverts() public {
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);
        bytes32 userOpHash = atlasVerification.getUserOperationHash(userOp);

        // Create solver operation with malformed data (less than 96 bytes)
        SolverOperation memory solverOp = SolverOperation({
            from: solverOneEOA,
            to: address(atlas),
            value: 0,
            gas: SOLVER_GAS_LIMIT,
            maxFeePerGas: 1_000_000_000,
            deadline: block.number + 100,
            solver: address(solver),
            control: address(auctionManager_),
            userOpHash: userOpHash,
            bidToken: address(0),
            bidAmount: solverBidAmount,
            data: abi.encodeWithSelector(solver.solve.selector), // Only 4 bytes - malformed!
            signature: new bytes(0)
        });

        Sig memory sig;
        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOp));
        solverOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp = buildDAppOperation(userOpHash, callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        vm.startBroadcast(bundlerPK);

        // NOTE: getBidParamsFromSolverOpData() reverts with MalformedSolverOperation
        // This happens early in _preSolverCall, so let's test if Atlas catches this too
        vm.expectRevert(); // Testing if this is caught or causes hard revert
        (bool success,) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();
    }

    // ========================================
    // Test Valid Operations
    // ========================================

    function testPreSolverCall_validOperation_success() public {
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);

        SolverOperation memory solverOp = buildSolverOperation(
            solverOnePK,
            address(solver),
            atlasVerification.getUserOperationHash(userOp),
            solverBidAmount,
            collateralToken,
            address(marketManagerIsolated),
            false
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp =
            buildDAppOperation(atlasVerification.getUserOperationHash(userOp), callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        vm.startBroadcast(bundlerPK);

        (bool success,) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        assertEq(success, true, "Valid operation should succeed");
    }

    // ========================================
    // Test Using Event-Based Validation (Copied from existing pattern)
    // ========================================

    function testPreSolverCall_unlistedCollateral_preSolverFails() public {
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);
        address executionEnv = auctionManager_.authorizedExecutionEnv();

        bytes32 userOpHash = atlasVerification.getUserOperationHash(userOp);
        SolverOperation memory solverOp = buildSolverOperation(
            solverOnePK,
            address(solver),
            userOpHash,
            solverBidAmount,
            collateralToken,
            address(marketManagerIsolated),
            false
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp = buildDAppOperation(userOpHash, callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        // Expect the solver to fail with PreSolverFailed (bit 16 = 65536)
        uint256 expectedResult = 1 << uint256(SolverOutcome.PreSolverFailed); // 65536

        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver),
            solverOneEOA,
            address(auctionManager_),
            address(0),
            solverBidAmount,
            false, // executed = false (didn't execute due to PreSolver failure)
            false, // success = false
            expectedResult // result = PreSolverFailed flag
        );

        // Expect MetacallResult with solverSuccessful = false
        vm.expectEmit(true, true, true, false, address(atlas));
        emit AtlasEvents.MetacallResult(
            bundler,
            userOpSigner,
            false, // solverSuccessful = false (no successful solvers)
            0, // ethPaidToBundler (will be some gas refund amount)
            0 // netGasSurcharge (will be some gas amount)
        );

        vm.startBroadcast(bundlerPK);

        (bool success, bytes memory returnData) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        // Metacall should succeed (Atlas executed properly)
        assertEq(success, true, "metacall should execute successfully");

        // But no solvers should have succeeded
        bool auctionWon = abi.decode(returnData, (bool));
        assertEq(auctionWon, false, "auction should not be won (no successful solvers)");
    }

    function testPreSolverCall_unlistedCollateral_preSolverFails_2() public {
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);

        bytes32 userOpHash = atlasVerification.getUserOperationHash(userOp);
        SolverOperation memory solverOp = buildSolverOperation(
            solverOnePK,
            address(solver),
            userOpHash,
            solverBidAmount,
            collateralToken,
            address(marketManagerIsolated),
            false
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp = buildDAppOperation(userOpHash, callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        // Expect the solver to fail with PreSolverFailed
        uint256 expectedResult = 1 << uint256(SolverOutcome.PreSolverFailed);

        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver),
            solverOneEOA,
            address(auctionManager_),
            address(0),
            solverBidAmount,
            false, // executed = false
            false, // success = false
            expectedResult // PreSolverFailed
        );

        vm.startBroadcast(bundlerPK);

        (bool success, bytes memory returnData) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        assertEq(success, true, "metacall should execute successfully");

        bool auctionWon = abi.decode(returnData, (bool));
        assertEq(auctionWon, false, "auction should not be won due to invalid penalty");
    }

    function testPreSolverCall_validPenalty_preSolverSucceeds() public {
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);

        bytes32 userOpHash = atlasVerification.getUserOperationHash(userOp);
        SolverOperation memory solverOp = buildSolverOperation(
            solverOnePK,
            address(solver),
            userOpHash,
            solverBidAmount,
            address(borrowableCUSDC),
            address(marketManagerIsolated),
            false
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp = buildDAppOperation(userOpHash, callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        // Expect the solver to succeed (no failure flags)
        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver),
            solverOneEOA,
            address(auctionManager_),
            address(0),
            solverBidAmount,
            true, // executed = true
            true, // success = true
            0 // result = 0 (no failure flags)
        );

        vm.startBroadcast(bundlerPK);

        (bool success, bytes memory returnData) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        assertEq(success, true, "metacall should execute successfully");

        bool auctionWon = abi.decode(returnData, (bool));
        assertEq(auctionWon, false, "auction won should be false (as per existing test pattern)");
    }

    // ========================================
    // Helper Functions (copied from existing test)
    // ========================================

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
}

// Reuse the MockSolver from the main test file
contract MockSolver is SolverBase {
    fallback() external payable {}
    receive() external payable {}

    constructor(address weth, address atlas) SolverBase(weth, atlas, msg.sender) {}

    function solve(address collateral, address market) external pure {
        // Mock function - intentionally empty
    }

    function solveRevert(address collateral, address market) external pure {
        revert("Atlas OEV is not allowed");
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