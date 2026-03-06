class CaptionErrorCode:
    CAPTION_EXTRACT_FAILED = "CAPTION_EXTRACT_FAILED"


class CaptionException(Exception):
    def __init__(self, code: str, message: str = None):
        self.code = code
        self.message = message or code
        super().__init__(self.message)
