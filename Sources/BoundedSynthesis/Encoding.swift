import TransitionSystem

enum BoSyEncodingError: Error {
    case EncodingFailed(String)
    case SolvingFailed(String)
}

public protocol BoSyEncoding {
    mutating func solve(forBound bound: Int) throws -> Bool
    func extractSolution() -> TransitionSystem?
}

public protocol SingleParamaterSearch: AnyObject {
    associatedtype Parameter: SynthesisParameter

    /**
     * Returns true when the synthesis problem has a solution for the given bound.
     */
    func solve(forBound bound: Parameter) throws -> Bool
}

extension SingleParamaterSearch {
    /**
     * Linear search for the smallest bound such that the synthesis problem has a solution.
     */
    public func searchMinimalLinear(cancelled: inout Bool) throws -> Parameter? {
        for i in Parameter.min ..< Parameter.max {
            if cancelled {
                return nil
            }
            let parameter = Parameter(value: i)
            if try solve(forBound: parameter) {
                return parameter
            }
        }
        return nil
    }

    /**
     * Exponential search for the smallest bound such that the synthesis problem has a solution.
     */
    public func searchMinimalExponential(cancelled: inout Bool) throws -> Parameter? {
        var i = Parameter.min
        assert(i > 0)
        while i < Parameter.max {
            if cancelled {
                return nil
            }
            let parameter = Parameter(value: i)
            if try solve(forBound: parameter) {
                return parameter
            }
            i *= 2
        }
        return nil
    }

    public func searchMinimalLinearSynth(cancelled: inout Bool) throws -> Parameter? {
        var i = Parameter.min
        assert(i > 0)
        while i < Parameter.max {
            if cancelled {
                return nil
            }
            let parameter = Parameter(value: i)
            if try solve(forBound: parameter) {
                return parameter
            }
            i = i + 1
        }
        return nil
    }

    public func searchMinimalHybrid(cancelled: inout Bool) throws -> Parameter? {

        var low = Parameter.min
        var high = Parameter.min

        assert(low > 0)

        // Phase 1:
        // Exponential search to find SAT upper bound

        while high < Parameter.max {

            if cancelled {
                return nil
            }

            let parameter = Parameter(value: high)

            if try solve(forBound: parameter) {
                break
            }

            low = high + 1
            high *= 2
        }

        // no solution found
        if high >= Parameter.max {
            return nil
        }

        // Phase 2:
        // Binary search refinement

        var best: Parameter? = nil

        while low <= high {

            if cancelled {
                return nil
            }

            let mid = low + (high - low) / 2
            let parameter = Parameter(value: mid)

            if try solve(forBound: parameter) {

                best = parameter
                high = mid - 1

            } else {

                low = mid + 1
            }
        }

        return best
    }
}