package red.ochsenbein.voidweaver.player;

import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy;

/**
 * When the player loads a failed item again.
 *
 * <p>A failed load is retried {@link #LOAD_RETRY_COUNT} times before the error is reported, with 0,
 * 1, 2, ... up to 5 s in between: about 25 s. ExoPlayer's default (3, a few seconds) turned a short
 * network drop while it loaded the next track into a load error, which cut off the end of the
 * current track and stopped playback.
 *
 * <p>Except when the server answered with a document instead of audio ({@link
 * MediaCache.ErrorDocumentException}): it gives the same answer again, so the error is reported at
 * once. Retrying would hold up playback for those 25 s for an unknown song, and with a password
 * changed on the server would cost each track that isn't cached 9 failed logins.
 */
final class LoadErrorPolicy extends DefaultLoadErrorHandlingPolicy {
  static final int LOAD_RETRY_COUNT = 8;

  LoadErrorPolicy() {
    super(LOAD_RETRY_COUNT);
  }

  @Override
  public long getRetryDelayMsFor(LoadErrorInfo loadErrorInfo) {
    if (isErrorDocument(loadErrorInfo.exception)) return C.TIME_UNSET;
    return super.getRetryDelayMsFor(loadErrorInfo);
  }

  private static boolean isErrorDocument(@Nullable Throwable error) {
    for (Throwable cause = error; cause != null; cause = cause.getCause()) {
      if (cause instanceof MediaCache.ErrorDocumentException) return true;
    }
    return false;
  }
}
