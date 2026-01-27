// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract SortedTrovesTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_setUp() public {
        assertEq(address(sortedTroves), address(troveManager.sorted_troves()), "E0");
        assertEq(address(sortedTroves.TROVE_MANAGER()), address(troveManager), "E1");
        assertEq(sortedTroves.empty(), true, "E2");
        assertEq(sortedTroves.size(), 0, "E3");
        assertEq(sortedTroves.first(), 0, "E4");
        assertEq(sortedTroves.last(), 0, "E5");
    }

    function test_sortedTroves_insert(
        uint256[10] memory _rates
    ) public {
        uint256 _minRate = troveManager.min_annual_interest_rate();
        uint256 _maxRate = troveManager.max_annual_interest_rate();
        uint256 _collateral = 10 * COLLATERAL_TOKEN_PRECISION;
        uint256 _debt = 1000 * BORROW_TOKEN_PRECISION;

        // Fund lender
        mintAndDepositIntoLender(userLender, _debt * 20);

        uint256[] memory _troveIds = new uint256[](10);
        uint256[] memory _boundedRates = new uint256[](10);

        for (uint256 i = 0; i < 10; i++) {
            _boundedRates[i] = bound(_rates[i], _minRate, _maxRate);
            address _user = address(uint160(i + 1));
            _troveIds[i] = mintAndOpenTrove(_user, _collateral, _debt, _boundedRates[i]);

            // Verify state after each insert
            assertEq(sortedTroves.size(), i + 1, "E0");
            assertEq(sortedTroves.empty(), false, "E1");
            assertEq(sortedTroves.contains(_troveIds[i]), true, "E2");
        }

        // Verify sorted order (descending by rate)
        uint256 _currentId = sortedTroves.first();
        uint256 _prevRate = type(uint256).max;
        uint256 _count = 0;

        while (_currentId != 0) {
            uint256 _nextId = sortedTroves.next(_currentId);

            // Check sorted order
            uint256 _currentRate = troveManager.troves(_currentId).annual_interest_rate;
            assertLe(_currentRate, _prevRate, "E3");

            // Verify prev/next links
            if (_nextId != 0) assertEq(sortedTroves.prev(_nextId), _currentId, "E4");
            else assertEq(sortedTroves.last(), _currentId, "E5");

            // Test valid_insert_position with a rate that fits between current and next
            uint256 _nextNodeRate = _nextId != 0 ? troveManager.troves(_nextId).annual_interest_rate : 0;
            if (_currentRate > _nextNodeRate) assertEq(sortedTroves.valid_insert_position(_currentRate, _currentId, _nextId), true, "E7");

            // Test find_insert_position returns valid position
            (uint256 _foundPrev, uint256 _foundNext) = sortedTroves.find_insert_position(_currentRate, 0, 0);
            assertEq(sortedTroves.valid_insert_position(_currentRate, _foundPrev, _foundNext), true, "E8");

            _prevRate = _currentRate;
            _currentId = _nextId;
            _count++;
        }

        assertEq(_count, 10, "E6");
    }

    function test_sortedTroves_remove(
        uint256[10] memory _rates
    ) public {
        uint256 _minRate = troveManager.min_annual_interest_rate();
        uint256 _maxRate = troveManager.max_annual_interest_rate();
        uint256 _collateral = 10 * COLLATERAL_TOKEN_PRECISION;
        uint256 _debt = 1000 * BORROW_TOKEN_PRECISION;

        // Fund lender
        mintAndDepositIntoLender(userLender, _debt * 20);

        uint256[] memory _troveIds = new uint256[](10);

        // Insert 10 troves
        for (uint256 i = 0; i < 10; i++) {
            uint256 _boundedRate = bound(_rates[i], _minRate, _maxRate);
            address _user = address(uint160(i + 1));
            _troveIds[i] = mintAndOpenTrove(_user, _collateral, _debt, _boundedRate);
        }

        assertEq(sortedTroves.size(), 10, "E0");

        // Remove troves one by one
        for (uint256 i = 0; i < 10; i++) {
            uint256 _troveId = _troveIds[i];
            uint256 _prevId = sortedTroves.prev(_troveId);
            uint256 _nextId = sortedTroves.next(_troveId);

            // Close the trove (which removes it from sorted list)
            address _owner = address(uint160(i + 1));
            uint256 _debtToRepay = troveManager.troves(_troveId).debt;
            airdrop(address(borrowToken), _owner, _debtToRepay);
            vm.startPrank(_owner);
            borrowToken.approve(address(troveManager), _debtToRepay);
            troveManager.close_trove(_troveId);
            vm.stopPrank();

            // Verify removal
            assertEq(sortedTroves.contains(_troveId), false, "E1");
            assertEq(sortedTroves.size(), 10 - i - 1, "E2");

            // Verify links are updated
            if (_prevId != 0 && _nextId != 0) {
                assertEq(sortedTroves.next(_prevId), _nextId, "E3");
                assertEq(sortedTroves.prev(_nextId), _prevId, "E4");
            } else if (_prevId == 0 && _nextId != 0) {
                assertEq(sortedTroves.first(), _nextId, "E5");
            } else if (_prevId != 0 && _nextId == 0) {
                assertEq(sortedTroves.last(), _prevId, "E6");
            }
        }

        // Verify list is empty
        assertEq(sortedTroves.empty(), true, "E7");
        assertEq(sortedTroves.size(), 0, "E8");
        assertEq(sortedTroves.first(), 0, "E9");
        assertEq(sortedTroves.last(), 0, "E10");
    }

    function test_sortedTroves_reInsert(
        uint256[10] memory _rates,
        uint256[10] memory _newRates
    ) public {
        uint256 _minRate = troveManager.min_annual_interest_rate();
        uint256 _maxRate = troveManager.max_annual_interest_rate();
        uint256 _collateral = 10 * COLLATERAL_TOKEN_PRECISION;
        uint256 _debt = 1000 * BORROW_TOKEN_PRECISION;

        // Fund lender
        mintAndDepositIntoLender(userLender, _debt * 20);

        uint256[] memory _troveIds = new uint256[](10);

        // Insert 10 troves
        for (uint256 i = 0; i < 10; i++) {
            uint256 _boundedRate = bound(_rates[i], _minRate, _maxRate);
            address _user = address(uint160(i + 1));
            _troveIds[i] = mintAndOpenTrove(_user, _collateral, _debt, _boundedRate);
        }

        // Re-insert each trove with a new rate
        for (uint256 i = 0; i < 10; i++) {
            uint256 _troveId = _troveIds[i];
            uint256 _oldRate = troveManager.troves(_troveId).annual_interest_rate;
            uint256 _newRate = bound(_newRates[i], _minRate, _maxRate);

            // Make sure new rate is different from old rate
            if (_newRate == _oldRate) _newRate = _oldRate == _maxRate ? _minRate : _oldRate + 1;

            address _owner = address(uint160(i + 1));

            // Adjust rate (which calls re_insert)
            vm.prank(_owner);
            troveManager.adjust_interest_rate(_troveId, _newRate, 0, 0, type(uint256).max);

            // Verify trove is still in list
            assertEq(sortedTroves.contains(_troveId), true, "E0");
            assertEq(sortedTroves.size(), 10, "E1");

            // Verify new rate
            assertEq(troveManager.troves(_troveId).annual_interest_rate, _newRate, "E2");
        }

        // Verify sorted order after all re-inserts
        uint256 _currentId = sortedTroves.first();
        uint256 _prevRate = type(uint256).max;
        uint256 _count = 0;

        while (_currentId != 0) {
            uint256 _currentRate = troveManager.troves(_currentId).annual_interest_rate;
            assertLe(_currentRate, _prevRate, "E3");

            uint256 _nextId = sortedTroves.next(_currentId);
            uint256 _prevId = sortedTroves.prev(_currentId);

            // Verify prev/next links
            if (_nextId != 0) assertEq(sortedTroves.prev(_nextId), _currentId, "E4");
            else assertEq(sortedTroves.last(), _currentId, "E5");

            if (_prevId != 0) assertEq(sortedTroves.next(_prevId), _currentId, "E6");
            else assertEq(sortedTroves.first(), _currentId, "E7");

            _prevRate = _currentRate;
            _currentId = _nextId;
            _count++;
        }

        assertEq(_count, 10, "E8");
    }

    function test_insert_notTroveManager(
        address _notTroveManager
    ) public {
        vm.assume(_notTroveManager != address(troveManager));

        vm.expectRevert("!trove_manager");
        vm.prank(_notTroveManager);
        sortedTroves.insert(1, 1e18, 0, 0);
    }

    function test_insert_troveExists() public {
        uint256 _collateral = 10 * COLLATERAL_TOKEN_PRECISION;
        uint256 _debt = 1000 * BORROW_TOKEN_PRECISION;

        mintAndDepositIntoLender(userLender, _debt);
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateral, _debt, troveManager.min_annual_interest_rate());

        vm.expectRevert("exists");
        vm.prank(address(troveManager));
        sortedTroves.insert(_troveId, 1e18, 0, 0);
    }

    function test_insert_invalidId() public {
        vm.expectRevert("!trove_id");
        vm.prank(address(troveManager));
        sortedTroves.insert(0, 1e18, 0, 0);
    }

    function test_remove_notTroveManager(
        address _notTroveManager
    ) public {
        vm.assume(_notTroveManager != address(troveManager));

        vm.expectRevert("!trove_manager");
        vm.prank(_notTroveManager);
        sortedTroves.remove(1);
    }

    function test_remove_troveDoesNotExist(
        uint256 _troveId
    ) public {
        vm.assume(_troveId != 0);

        vm.expectRevert("!exists");
        vm.prank(address(troveManager));
        sortedTroves.remove(_troveId);
    }

    function test_reInsert_notTroveManager(
        address _notTroveManager
    ) public {
        vm.assume(_notTroveManager != address(troveManager));

        vm.expectRevert("!trove_manager");
        vm.prank(_notTroveManager);
        sortedTroves.re_insert(1, 1e18, 0, 0);
    }

    function test_reInsert_troveDoesNotExist(
        uint256 _troveId
    ) public {
        vm.assume(_troveId != 0);

        vm.expectRevert("!exists");
        vm.prank(address(troveManager));
        sortedTroves.re_insert(_troveId, 1e18, 0, 0);
    }

}

