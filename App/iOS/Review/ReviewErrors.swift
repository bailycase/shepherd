import ShepherdRemote

func reviewErrorText(_ error: Error) -> String {
    if case RemoteHostClientError.rejected(_, let message) = error { return message }
    return String(describing: error)
}
