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
import {IMarketManager} from "contracts/interfaces/IMarketManager.sol";
import { AuctionManager } from "src/AuctionManager.sol";
import { ChainlinkWrapperEntrypoint } from "src/ChainlinkWrapperEntrypoint.sol";
import { ChainlinkCurvanceOEVWrapper } from "src/ChainlinkCurvanceOEVWrapper.sol";

import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { console2 } from "forge-std/console2.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD_SQUARED, WAD_SQUARED_BPS_OFFSET } from "contracts/libraries/ConstantsLib.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { BPS, WAD } from "contracts/libraries/ConstantsLib.sol";

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

    address public unlistedToken = address(0xccccccc); // Unlisted collateral token for testing

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

    uint256 userOpSignerPK = 0xDEADBEEF123456789ABCDEF;
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
            OEV_SHARE_FASTLANE,
            OEV_ALLOCATION_DESTINATION_FASTLANE,
            OEV_ALLOCATION_DESTINATION_PROTOCOL
        );

        auctionManager_.setCentralRegistry(ICentralRegistry(address(centralRegistry)));
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

        // DIFFERENCE: MockSolver now needs all contract addresses passed to constructor
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

        // DIFFERENCE: Give solver USDC for liquidation (reference file line 71)
        // NOTE: In reference, liquidator calls _prepareUSDC, but solver can't do that, so we give it USDC here
        _prepareUSDC(address(solver), 1000e6);

        // ========================================
        // Liquidation setup - copied from AuctionDerivedIncentiveAndCloseFactor.t.sol setUp()
        // DIFFERENCE: Using centralRegistry.daoAddress() instead of address(this) because we need proper permissions
        // ========================================
        vm.startPrank(centralRegistry.daoAddress());

        // IDENTICAL: Market setup from reference file lines 43-44
        _prepareDAI(centralRegistry.daoAddress(), 77777);
        _prepareUSDC(centralRegistry.daoAddress(), 100_000e6 + 77777);

        // IDENTICAL: Token approvals from reference file lines 46-47
        usdc.approve(address(borrowableCUSDC), 100_000e18 + 77777);
        dai.approve(address(borrowableCDAI), 77777);

        // DIFFERENCE: Tokens already listed earlier at line 133, so NOT calling marketManagerIsolated.listTokens() again
        // Reference file line 49 calls: marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

        // DIFFERENCE: Config already set earlier at lines 134-135, so NOT calling _setCTokenConfigBasic() again
        // Reference file lines 51-52 call: _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e6, 100_000e6); etc.

        // IDENTICAL: Deposit USDC from reference file line 54
        borrowableCUSDC.deposit(100_000e6, centralRegistry.daoAddress());

        // IDENTICAL: Set initial prices from reference file lines 56-57
        mockUsdcFeed.setMockAnswer(1e8);
        mockDaiFeed.setMockAnswer(1e8);

        vm.stopPrank();

        // IDENTICAL: Set up user positions from reference file lines 60-65
        vm.startPrank(user1);
        _prepareDAI(user1, 1000e18);
        dai.approve(address(borrowableCDAI), 1000e18);
        borrowableCDAI.depositAsCollateral(1000e18, user1);
        borrowableCUSDC.borrow(500e6, user1);
        vm.stopPrank();

        // IDENTICAL: Drop DAI price to make position liquidatable from reference file line 67
        mockDaiFeed.setMockAnswer(70007000);
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
            address(borrowableCUSDC), // Use valid collateral
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

        // Expect the oracle update to happen successfully (before solver execution)
        vm.expectEmit(true, false, false, true, address(wrapperEntrypoint));
        emit ChainlinkWrapperEntrypoint.BatchUpdateExecuted(
            address(auctionManager_), // updater is the dapp control
            2, // totalWrappers
            2  // successfulUpdates
        );

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

        // Expect MetacallResult - only checking indexed params (bundler, user)
        vm.expectEmit(true, true, false, false, address(atlas));
        emit AtlasEvents.MetacallResult(
            bundler,
            userOpSigner,
            false, // solverSuccessful = false
            0, // ethPaidToBundler
            0 // netGasSurcharge
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
    // Test Collateral Mismatch
    // ========================================

    function testPreSolverCall_mismatchedCollateral_preSolverFails() public {
        // Test where both collaterals are valid/listed, but there's a mismatch:
        // - Solver data specifies one collateral (gets unlocked in preSolverCall)
        // - But solver attempts liquidation with a different collateral
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

        // Expect the oracle update to happen successfully (before solver execution)
        vm.expectEmit(true, false, false, true, address(wrapperEntrypoint));
        emit ChainlinkWrapperEntrypoint.BatchUpdateExecuted(
            address(auctionManager_), // updater is the dapp control
            2, // totalWrappers
            2  // successfulUpdates
        );

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

        // Expect MetacallResult - only checking indexed params (bundler, user)
        vm.expectEmit(true, true, false, false, address(atlas));
        emit AtlasEvents.MetacallResult(
            bundler,
            userOpSigner,
            false, // solverSuccessful = false
            0, // ethPaidToBundler
            0 // netGasSurcharge
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
    // Test Unlisted Collateral Rejection
    // ========================================

    function testPreSolverCall_unlistedCollateral_preSolverFailsLegacy() public {
        // NOTE: This test validates that PreSolver fails when attempting to set
        // transient liquidation config for an unlisted collateral token.
        // The unlistedToken (0xccccccc) is not configured in the MarketManagerIsolated,
        // so the Curvance protocol rejects it when setTransientLiquidationConfig is called.
        // AuctionManager always uses (0, 0) for protocol-derived incentive and close factor.
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);

        SolverOperation memory solverOp = buildSolverOperation(
            solverOnePK,
            address(solver),
            atlasVerification.getUserOperationHash(userOp),
            solverBidAmount,
            unlistedToken, // Unlisted collateral - not configured in MarketManagerIsolated
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

        // Expect the oracle update to happen successfully (before solver execution)
        vm.expectEmit(true, false, false, true, address(wrapperEntrypoint));
        emit ChainlinkWrapperEntrypoint.BatchUpdateExecuted(
            address(auctionManager_), // updater is the dapp control
            2, // totalWrappers
            2  // successfulUpdates
        );

        // Expect the solver to fail with PreSolverFailed due to unlisted collateral
        // Curvance rejects setTransientLiquidationConfig for tokens not configured in the market
        uint256 expectedResult = 1 << uint256(SolverOutcome.PreSolverFailed);

        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver),
            solverOneEOA,
            address(auctionManager_),
            address(0),
            solverBidAmount,
            false, // executed = false (PreSolver failed - unlisted collateral)
            false, // success = false
            expectedResult // PreSolverFailed
        );

        // Expect MetacallResult - only checking indexed params (bundler, user)
        vm.expectEmit(true, true, false, false, address(atlas));
        emit AtlasEvents.MetacallResult(
            bundler,
            userOpSigner,
            false, // solverSuccessful = false (no successful solvers)
            0, // ethPaidToBundler
            0 // netGasSurcharge
        );

        vm.startBroadcast(bundlerPK);

        (bool success, bytes memory returnData) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        // Atlas handles the failure gracefully:
        assertEq(success, true, "metacall should succeed even with unlisted collateral");
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

        // Expect the oracle update to happen successfully (before solver execution)
        vm.expectEmit(true, false, false, true, address(wrapperEntrypoint));
        emit ChainlinkWrapperEntrypoint.BatchUpdateExecuted(
            address(auctionManager_), // updater is the dapp control
            2, // totalWrappers (wrapper1 and wrapper2)
            2  // successfulUpdates (both should succeed)
        );

        // Expect the solver to fail with PreSolverFailed due to malformed data
        uint256 expectedResult = 1 << uint256(SolverOutcome.PreSolverFailed);

        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver),
            solverOneEOA,
            address(auctionManager_),
            address(0),
            solverBidAmount,
            false, // executed = false (PreSolver failed - malformed data)
            false, // success = false
            expectedResult // PreSolverFailed
        );

        // Expect MetacallResult - only checking indexed params (bundler, user)
        vm.expectEmit(true, true, false, false, address(atlas));
        emit AtlasEvents.MetacallResult(
            bundler,
            userOpSigner,
            false, // solverSuccessful = false
            0, // ethPaidToBundler
            0 // netGasSurcharge
        );

        vm.startBroadcast(bundlerPK);

        (bool success, bytes memory returnData) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        // Atlas should handle the malformed data gracefully
        assertEq(success, true, "metacall should succeed even with malformed solver data");
        bool auctionWon = abi.decode(returnData, (bool));
        assertEq(auctionWon, false, "auction should not be won due to malformed data");
    }

    function testPreSolverCall_validPenalty_preSolverSucceeds() public {
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);

        bytes32 userOpHash = atlasVerification.getUserOperationHash(userOp);
        SolverOperation memory solverOp = buildSolverOperation(
            solverOnePK,
            address(solver),
            userOpHash,
            solverBidAmount,
            address(borrowableCDAI), // DIFFERENCE: Pass collateral token (DAI), not debt token (USDC)
            address(marketManagerIsolated),
            false
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp = buildDAppOperation(userOpHash, callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        // Record AuctionManager balance before metacall
        uint256 auctionManagerBalanceBefore = address(auctionManager_).balance;

        // Track solver collateral balance before metacall
        uint256 solverCollBefore = borrowableCDAI.balanceOf(address(solver));

        // Track user debt balance and lFactor before metacall (needed for expected collateral calculation)
        // All liquidation state must be captured BEFORE metacall since user position changes after liquidation
        uint256 user1DebtBefore = borrowableCUSDC.debtBalanceUpdated(user1);
        (, , , uint256 user1LFactorBefore) = _liquidationValuesOfHelper(marketManagerIsolated, user1);

        // ============================================
        // PART 1: WITHOUT AUCTION - Should FAIL
        // ============================================

        // Try to liquidate WITHOUT auction setup (no unlock, no transient config)
        address[] memory borrowersToLiquidate = new address[](1);
        borrowersToLiquidate[0] = user1;

        // CRITICAL CURVANCE VALIDATION: Should fail because user is (barely) healthy
        // The solver contract calls liquidate directly, not via Atlas
        vm.prank(solverOneEOA);
        vm.expectRevert(abi.encodeWithSignature("MarketManager__NoLiquidationAvailable()"));
        solver.callLiquidateDirectly(
            address(borrowableCUSDC),
            borrowersToLiquidate,
            address(borrowableCDAI)
        );

        // ============================================
        // PART 2: WITH AUCTION - Should SUCCEED
        // ============================================

        // Expect the oracle update to happen successfully (before solver execution)
        vm.expectEmit(true, false, false, true, address(wrapperEntrypoint));
        emit ChainlinkWrapperEntrypoint.BatchUpdateExecuted(
            address(auctionManager_), // updater is the dapp control
            2, // totalWrappers
            2  // successfulUpdates
        );

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

        // Expect revenue to be allocated to AuctionManager
        vm.expectEmit(true, false, false, true, address(auctionManager_));
        emit AuctionManager.RevenueAllocated(solverBidAmount);

        // Expect MetacallResult - only checking indexed params (bundler, user), not gas values
        vm.expectEmit(true, true, false, false, address(atlas));
        emit AtlasEvents.MetacallResult(
            bundler,
            userOpSigner,
            false, // solverSuccessful = false (always false in this DApp config, not a failure)
            0, // ethPaidToBundler
            0 // netGasSurcharge
        );

        vm.startBroadcast(bundlerPK);

        (bool success, bytes memory returnData) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        assertEq(success, true, "metacall should execute successfully");

        bool auctionWon = abi.decode(returnData, (bool));
        assertEq(auctionWon, false, "auctionWon = false (DApp config), but revenue is allocated");

        // Verify solver received exact amount of seized collateral
        uint256 solverCollAfter = borrowableCDAI.balanceOf(address(solver));

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
            solverCollAfter - solverCollBefore,
            expectedCollateral,
            "solver collateral increase doesn't match expected seized amount"
        );

        // Verify AuctionManager balance increased by solverBidAmount
        uint256 auctionManagerBalanceAfter = address(auctionManager_).balance;
        assertEq(
            auctionManagerBalanceAfter,
            auctionManagerBalanceBefore + solverBidAmount,
            "AuctionManager should have received solver bid amount as revenue"
        );
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

// Reuse the MockSolver from the main test file
// DIFFERENCE: MockSolver stores contract addresses instead of inheriting TestBaseMarketIsolated state
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

        // IDENTICAL: Validate transient liquidation config was set correctly (reference file lines 80-86)
        (address storedCollateral, uint256 storedIncentive, uint256 storedCloseFactor) =
            marketManager.getTransientLiquidationConfig();

        require(storedCollateral == collateral, "MockSolver: collateral mismatch");
        require(storedIncentive == 0, "Incentive should be stored as 0 to signal protocol-derived");
        require(storedCloseFactor == 0, "Close factor should be stored as 0 to signal protocol-derived");

        // DIFFERENCE: Solver already has USDC from setUp(), just approve (reference file line 74)
        // NOTE: _prepareUSDC() removed - solver receives USDC in test setUp()
        usdc.approve(address(borrowableCUSDC), 1000e6);

        address user1 = borrowers[0];

        // IDENTICAL: Get balances before liquidation (reference file lines 99-100)
        uint256 debtBefore = borrowableCUSDC.debtBalanceUpdated(user1);
        uint256 collateralBefore = borrowableCDAI.balanceOf(user1);

        uint256 expectedMaxDebtRepaid;
        uint256 expectedCollateralSeized;
        {
            // IDENTICAL: Get protocol liquidation config (reference file lines 105-107)
            (uint256 liqIncBase, uint256 liqIncCurve, , , uint256 closeFactorBase, uint256 closeFactorCurve,,)
                = marketManagerIsolated.liquidationConfig(address(borrowableCDAI));

            // IDENTICAL: Get lFactor for borrower (reference file line 111)
            (, , , uint256 lFactor) = _liquidationValuesOfHelper(marketManagerIsolated, user1);

            // VERIFY AUCTION BUFFER WAS APPLIED TO LFACTOR CALCULATION
            uint256 auctionBuffer = marketManagerIsolated.AUCTION_BUFFER();
            require(auctionBuffer == 9950, "Auction buffer must be 9950 (50bps)");

            // VERIFY CURVE VALUES ARE NON-ZERO (protocol-derived actually used curves)
            require(liqIncCurve > 0, "CURVANCE BUG: liqIncCurve is zero, protocol-derived won't work");
            require(closeFactorCurve > 0, "CURVANCE BUG: closeFactorCurve is zero, protocol-derived won't work");
            require(lFactor > 0, "CURVANCE BUG: lFactor is zero, user shouldn't be liquidatable");

            // IDENTICAL: Calculate expected close factor (reference file line 123)
            uint256 expectedCloseFactor = closeFactorBase + ((closeFactorCurve * lFactor) / 1e18);

            // IDENTICAL: Calculate expected liquidation incentive (reference file line 126)
            uint256 expectedLiqIncentive = liqIncBase + ((liqIncCurve * lFactor) / 1e18);

            // IDENTICAL: Calculate expected max debt repaid (reference file line 129)
            expectedMaxDebtRepaid = (debtBefore * expectedCloseFactor) / 10000;

            // IDENTICAL: Calculate expected collateral seized (reference file lines 132-137)
            expectedCollateralSeized = _calculateExpectedCollateralSeized(
                expectedMaxDebtRepaid,
                expectedLiqIncentive,
                address(borrowableCDAI),
                address(borrowableCUSDC)
            );
        }

        // IDENTICAL: Execute liquidation (reference file line 141)
        borrowableCUSDC.liquidate(borrowers, address(borrowableCDAI));

        // IDENTICAL: Get balances after liquidation (reference file lines 146-151)
        uint256 debtAfter = borrowableCUSDC.debtBalanceUpdated(user1);
        uint256 collateralAfter = borrowableCDAI.balanceOf(user1);

        uint256 debtRepaid = debtBefore - debtAfter;
        uint256 collateralSeized = collateralBefore - collateralAfter;

        // IDENTICAL: Verify debt repaid matches expected (reference file lines 157-158)
        require(debtRepaid == expectedMaxDebtRepaid,
            "Debt repaid must exactly match expected value from protocol-derived close factor");

        // IDENTICAL: Verify collateral seized matches expected (reference file lines 162-163)
        require(collateralSeized == expectedCollateralSeized,
            "Collateral seized must exactly match expected value from protocol-derived liquidation incentive");

        // Verify user is now healthy after liquidation
        (, uint256 maxDebtAfter, uint256 debtAfterLiq) = marketManagerIsolated.statusOf(user1);
        require(debtAfterLiq <= maxDebtAfter,
            "CURVANCE BUG: User must be healthy after liquidation");
    }

    // IDENTICAL: Helper function to calculate expected collateral seized (reference file lines 177-210)
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

        address[] memory borrowers = new address[](1);
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