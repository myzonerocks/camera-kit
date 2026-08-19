import CGosslens

/// Mirrors goss_status - thrown by every wrapper method whose C call can
/// fail, carrying the real status code rather than collapsing it to Bool.
public enum GossStatus: Error {
    case invalidArgument
    case outOfMemory
    case poolExhausted
    case abiMismatch
    case rendererUnavailable
    case unsupported
    case again

    init?(_ raw: goss_status) {
        switch raw {
        case GOSS_OK: return nil
        case GOSS_ERROR_INVALID_ARGUMENT: self = .invalidArgument
        case GOSS_ERROR_OUT_OF_MEMORY: self = .outOfMemory
        case GOSS_ERROR_POOL_EXHAUSTED: self = .poolExhausted
        case GOSS_ERROR_ABI_MISMATCH: self = .abiMismatch
        case GOSS_ERROR_RENDERER_UNAVAILABLE: self = .rendererUnavailable
        case GOSS_ERROR_UNSUPPORTED: self = .unsupported
        case GOSS_AGAIN: self = .again
        default: self = .invalidArgument
        }
    }
}

func checked(_ raw: goss_status) throws {
    if let status = GossStatus(raw) { throw status }
}
