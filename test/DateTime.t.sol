// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/DateTime.sol";

/**
 * @title DateTimeTest
 * @notice Comprehensive tests for DateTime library
 * @dev Tests edge cases: leap years, month boundaries, year boundaries
 */
contract DateTimeTest is Test {
    using DateTime for uint256;

    /**
     * Test basic date conversion
     */
    function testBasicDateConversion() public {
        // January 1, 2024 00:00:00 UTC
        uint256 timestamp = 1704067200;
        (uint256 year, uint256 month, uint256 day) = timestamp.timestampToDate();

        assertEq(year, 2024);
        assertEq(month, 1);
        assertEq(day, 1);
    }

    /**
     * Test leap year - February 29, 2024
     */
    function testLeapYear() public {
        // February 29, 2024 00:00:00 UTC
        uint256 timestamp = 1709164800;
        (uint256 year, uint256 month, uint256 day) = timestamp.timestampToDate();

        assertEq(year, 2024);
        assertEq(month, 2);
        assertEq(day, 29);

        assertTrue(DateTime.isLeapYear(2024));
        assertFalse(DateTime.isLeapYear(2023));
    }

    /**
     * Test non-leap year February
     */
    function testNonLeapYear() public {
        // February 28, 2023 23:59:59 UTC (last second before March)
        uint256 timestamp = 1677628799;
        (uint256 year, uint256 month, uint256 day) = timestamp.timestampToDate();

        assertEq(year, 2023);
        assertEq(month, 2);
        assertEq(day, 28);

        assertFalse(DateTime.isLeapYear(2023));
    }

    /**
     * Test year boundary transition
     */
    function testYearBoundary() public {
        // December 31, 2023 23:59:59 UTC
        uint256 timestamp = 1704067199;
        (uint256 year, uint256 month, uint256 day) = timestamp.timestampToDate();

        assertEq(year, 2023);
        assertEq(month, 12);
        assertEq(day, 31);

        // January 1, 2024 00:00:00 UTC (next second)
        timestamp = 1704067200;
        (year, month, day) = timestamp.timestampToDate();

        assertEq(year, 2024);
        assertEq(month, 1);
        assertEq(day, 1);
    }

    /**
     * Test month boundaries
     */
    function testMonthBoundaries() public {
        // Test 31-day month (January 31, 2024)
        uint256 timestamp = 1706659200;
        (uint256 year, uint256 month, uint256 day) = timestamp.timestampToDate();
        assertEq(year, 2024);
        assertEq(month, 1);
        assertEq(day, 31);

        // Test 30-day month (April 30, 2024)
        timestamp = 1714435200;
        (year, month, day) = timestamp.timestampToDate();
        assertEq(year, 2024);
        assertEq(month, 4);
        assertEq(day, 30);
    }

    /**
     * Test date string formatting
     */
    function testDateStringFormat() public {
        // February 5, 2024 00:00:00 UTC
        uint256 timestamp = 1707091200;
        string memory dateStr = timestamp.timestampToDateString();

        assertEq(dateStr, "2024-02-05");
    }

    /**
     * Test single-digit month and day padding
     */
    function testDateStringPadding() public {
        // March 9, 2024 00:00:00 UTC
        uint256 timestamp = 1709942400;
        string memory dateStr = timestamp.timestampToDateString();

        assertEq(dateStr, "2024-03-09");
    }

    /**
     * Test double-digit month and day
     */
    function testDateStringDoubleDigit() public {
        // December 25, 2024 00:00:00 UTC
        uint256 timestamp = 1735084800;
        string memory dateStr = timestamp.timestampToDateString();

        assertEq(dateStr, "2024-12-25");
    }

    /**
     * Test epoch (January 1, 1970)
     */
    function testEpoch() public {
        uint256 timestamp = 0;
        (uint256 year, uint256 month, uint256 day) = timestamp.timestampToDate();

        assertEq(year, 1970);
        assertEq(month, 1);
        assertEq(day, 1);

        string memory dateStr = timestamp.timestampToDateString();
        assertEq(dateStr, "1970-01-01");
    }

    /**
     * Test getDaysInMonth for all months
     */
    function testGetDaysInMonth() public {
        assertEq(DateTime.getDaysInMonth(2024, 1), 31); // January
        assertEq(DateTime.getDaysInMonth(2024, 2), 29); // February (leap year)
        assertEq(DateTime.getDaysInMonth(2023, 2), 28); // February (non-leap year)
        assertEq(DateTime.getDaysInMonth(2024, 3), 31); // March
        assertEq(DateTime.getDaysInMonth(2024, 4), 30); // April
        assertEq(DateTime.getDaysInMonth(2024, 5), 31); // May
        assertEq(DateTime.getDaysInMonth(2024, 6), 30); // June
        assertEq(DateTime.getDaysInMonth(2024, 7), 31); // July
        assertEq(DateTime.getDaysInMonth(2024, 8), 31); // August
        assertEq(DateTime.getDaysInMonth(2024, 9), 30); // September
        assertEq(DateTime.getDaysInMonth(2024, 10), 31); // October
        assertEq(DateTime.getDaysInMonth(2024, 11), 30); // November
        assertEq(DateTime.getDaysInMonth(2024, 12), 31); // December
    }

    /**
     * Test leap year rules (divisible by 4, but not 100, unless also 400)
     */
    function testLeapYearRules() public {
        // Divisible by 4, not 100 -> leap year
        assertTrue(DateTime.isLeapYear(2024));
        assertTrue(DateTime.isLeapYear(2028));

        // Not divisible by 4 -> not leap year
        assertFalse(DateTime.isLeapYear(2023));
        assertFalse(DateTime.isLeapYear(2025));

        // Divisible by 100, not 400 -> not leap year
        assertFalse(DateTime.isLeapYear(1900));
        assertFalse(DateTime.isLeapYear(2100));

        // Divisible by 400 -> leap year
        assertTrue(DateTime.isLeapYear(2000));
        assertTrue(DateTime.isLeapYear(2400));
    }

    /**
     * Test multiple years
     */
    function testMultipleYears() public {
        // Test a date from each year 2020-2026
        uint256[7] memory timestamps = [
            uint256(1577836800), // 2020-01-01
            uint256(1609459200), // 2021-01-01
            uint256(1640995200), // 2022-01-01
            uint256(1672531200), // 2023-01-01
            uint256(1704067200), // 2024-01-01
            uint256(1735689600), // 2025-01-01
            uint256(1767225600) // 2026-01-01
        ];

        for (uint256 i = 0; i < 7; i++) {
            (uint256 year, uint256 month, uint256 day) = timestamps[i].timestampToDate();
            assertEq(year, 2020 + i);
            assertEq(month, 1);
            assertEq(day, 1);
        }
    }

    /**
     * Fuzz test: Verify all dates in 2024
     */
    function testFuzz_Dates2024(uint256 dayOfYear) public {
        // 2024 is a leap year (366 days)
        dayOfYear = bound(dayOfYear, 0, 365);

        // Start of 2024: January 1, 2024 00:00:00 UTC
        uint256 timestamp = 1704067200 + (dayOfYear * 1 days);

        (uint256 year, uint256 month, uint256 day) = timestamp.timestampToDate();

        // Should always be 2024
        assertEq(year, 2024);

        // Month should be 1-12
        assertTrue(month >= 1 && month <= 12);

        // Day should be valid for the month
        assertTrue(day >= 1 && day <= DateTime.getDaysInMonth(2024, month));
    }

    /**
     * Test real-world weather option dates
     */
    function testWeatherOptionDates() public {
        // Example: 90-day weather option starting June 1, 2024
        uint256 startDate = 1717200000; // June 1, 2024 00:00:00 UTC
        uint256 expiryDate = startDate + 90 days;

        string memory startStr = startDate.timestampToDateString();
        string memory expiryStr = expiryDate.timestampToDateString();

        assertEq(startStr, "2024-06-01");
        assertEq(expiryStr, "2024-08-30");
    }
}
