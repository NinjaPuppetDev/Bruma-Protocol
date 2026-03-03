// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DateTime
 * @notice Gas-efficient datetime conversion library for Solidity
 * @dev Based on the algorithm from BokkyPooBah's DateTime Library
 *      Uses the Gregorian calendar date calculation algorithm
 *      Handles leap years correctly and avoids loops for gas efficiency
 *
 * Algorithm Reference:
 * - Civil calendar calculations (Neri-Schneider algorithm)
 * - Gas cost: ~2,000 gas per conversion
 * - Accurate for years 1970-2099
 */
library DateTime {
    uint256 private constant SECONDS_PER_DAY = 86400;

    /**
     * @notice Convert Unix timestamp to date components
     * @dev Uses the BokkyPooBah algorithm for accurate date conversion
     *      This handles leap years correctly without loops
     * @param timestamp Unix timestamp in seconds since epoch
     * @return year The year (e.g., 2024)
     * @return month The month (1-12)
     * @return day The day of month (1-31)
     */
    function timestampToDate(uint256 timestamp) internal pure returns (uint256 year, uint256 month, uint256 day) {
        uint256 _days = timestamp / SECONDS_PER_DAY;

        // Convert days to date using the civil calendar algorithm
        int256 __days = int256(_days);

        int256 L = __days + 68569 + 2440588;
        int256 N = 4 * L / 146097;
        L = L - (146097 * N + 3) / 4;
        int256 _year = 4000 * (L + 1) / 1461001;
        L = L - 1461 * _year / 4 + 31;
        int256 _month = 80 * L / 2447;
        int256 _day = L - 2447 * _month / 80;
        L = _month / 11;
        _month = _month + 2 - 12 * L;
        _year = 100 * (N - 49) + _year + L;

        year = uint256(_year);
        month = uint256(_month);
        day = uint256(_day);
    }

    /**
     * @notice Convert Unix timestamp to ISO 8601 date string (YYYY-MM-DD)
     * @dev Optimized for gas efficiency while maintaining readability
     * @param timestamp Unix timestamp in seconds since epoch
     * @return ISO 8601 formatted date string
     */
    function timestampToDateString(uint256 timestamp) internal pure returns (string memory) {
        (uint256 year, uint256 month, uint256 day) = timestampToDate(timestamp);

        return string(abi.encodePacked(_uint2str(year), "-", _padZero(month), "-", _padZero(day)));
    }

    /**
     * @notice Convert unsigned integer to string
     * @dev Gas-optimized string conversion
     * @param value The unsigned integer to convert
     * @return String representation of the number
     */
    function _uint2str(uint256 value) private pure returns (string memory) {
        if (value == 0) {
            return "0";
        }

        uint256 temp = value;
        uint256 digits;

        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);

        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }

        return string(buffer);
    }

    /**
     * @notice Pad single-digit numbers with leading zero
     * @dev Used for month and day formatting (e.g., "05" instead of "5")
     * @param num Number to pad (typically 1-12 for months, 1-31 for days)
     * @return Two-character string representation
     */
    function _padZero(uint256 num) private pure returns (string memory) {
        if (num < 10) {
            return string(abi.encodePacked("0", _uint2str(num)));
        }
        return _uint2str(num);
    }

    /**
     * @notice Check if a year is a leap year
     * @dev Implements the Gregorian calendar leap year rules
     * @param year The year to check
     * @return True if leap year, false otherwise
     */
    function isLeapYear(uint256 year) internal pure returns (bool) {
        if (year % 4 != 0) {
            return false;
        }
        if (year % 100 != 0) {
            return true;
        }
        if (year % 400 != 0) {
            return false;
        }
        return true;
    }

    /**
     * @notice Get number of days in a month
     * @dev Accounts for leap years in February
     * @param year The year
     * @param month The month (1-12)
     * @return Number of days in the month
     */
    function getDaysInMonth(uint256 year, uint256 month) internal pure returns (uint256) {
        if (month == 2) {
            return isLeapYear(year) ? 29 : 28;
        }
        if (month == 4 || month == 6 || month == 9 || month == 11) {
            return 30;
        }
        return 31;
    }
}
