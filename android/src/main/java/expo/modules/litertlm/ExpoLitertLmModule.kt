package expo.modules.litertlm

import android.os.Build
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import com.google.ai.edge.litertlm.Backend as LiteRtLmBackend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.ExperimentalApi
import com.google.ai.edge.litertlm.ExperimentalFlags
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.MessageCallback
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInference.Backend as TasksGenaiBackend
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession
import expo.modules.kotlin.exception.Exceptions
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.atomic.AtomicReference

private enum class LoadedRuntime {
  TASKS_GENAI,
  LITERT_LM,
}

class ExpoLitertLmModule : Module() {
  init {
    // Set the MTP / speculative-decoding flag once at module construction,
    // before any LiteRT-LM JNI bridge calls. The earlier in-flow set of this
    // flag (at loadModelAsync time) was empirically a no-op — the engine
    // logged `enable_speculative_decoding: false` even when our Kotlin code
    // had set the property to true. Hypothesis: the JNI bridge captures the
    // value once at SDK static init, so it must be set before the first
    // EngineConfig() / Engine() call. Module init runs when Expo first
    // instantiates the module, which is reliably before any engine creation.
    @OptIn(ExperimentalApi::class)
    ExperimentalFlags.enableSpeculativeDecoding = true
  }

  private var llmInference: LlmInference? = null
  private var litertLmEngine: Engine? = null
  private var loadedModelPath: String? = null
  private var loadedRuntime: LoadedRuntime? = null
  private var activeSession: LlmInferenceSession? = null
  private var activeConversation: Conversation? = null
  private var generationTopK: Int = 40
  private var generationTemperature: Float = 0.8f
  private var generationTopP: Double = 0.95

  override fun definition() = ModuleDefinition {
    Name("ExpoLitertLm")
    Events("onToken")

    AsyncFunction("isAvailableAsync") {
      Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
    }

    AsyncFunction(
      "loadModelAsync"
    ) { modelPath: String, maxTokens: Int, topK: Int, temperature: Double, preferredBackend: String? ->
      if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
        throw IllegalStateException("LiteRT models require Android 12 or newer.")
      }

      val context = appContext.reactContext ?: throw Exceptions.ReactContextLost()
      if (loadedModelPath == modelPath && isEnginePrepared()) {
        return@AsyncFunction mapOf(
          "modelPath" to modelPath,
          "backend" to (preferredBackend ?: defaultBackendName(modelPath)).lowercase(),
        )
      }

      unloadInternal()

      generationTopK = topK.coerceAtLeast(1)
      generationTemperature = temperature.toFloat()

      if (isLiteRtLmModelPath(modelPath)) {
        val resolvedBackendName = preferredBackend ?: defaultBackendName(modelPath)
        // Gemma 4 Multi-Token Prediction (>2x decode speedup) is universally recommended
        // for GPU backends per https://ai.google.dev/edge/litert-lm/models/gemma-4. The
        // flag is a global static, must be set before Engine init, and only helps when
        // the engine is running on GPU — leave it false for explicit-CPU sessions.
        @OptIn(ExperimentalApi::class)
        run {
          ExperimentalFlags.enableSpeculativeDecoding = resolvedBackendName.uppercase() != "CPU"
        }
        // EngineConfig in litertlm-android 0.11.0 added a `maxNumImages` parameter
        // between `maxNumTokens` and `cacheDir`, and renamed the int-positional slot
        // from `maxTokens` to `maxNumTokens`. Use named arguments so any future
        // parameter shuffles in the SDK fail at the call site, not silently.
        val engineConfig = EngineConfig(
          modelPath = modelPath,
          backend = resolveLiteRtLmBackend(resolvedBackendName),
          visionBackend = null,
          audioBackend = LiteRtLmBackend.CPU(),
          maxNumTokens = maxTokens,
          maxNumImages = null,
          cacheDir = context.cacheDir.absolutePath,
        )
        val engine = Engine(engineConfig)
        engine.initialize()
        litertLmEngine = engine
        loadedRuntime = LoadedRuntime.LITERT_LM
        loadedModelPath = modelPath
        return@AsyncFunction mapOf(
          "modelPath" to modelPath,
          "backend" to resolvedBackendName.lowercase(),
        )
      }

      val optionsBuilder = LlmInference.LlmInferenceOptions.builder()
      optionsBuilder.setModelPath(modelPath)
      optionsBuilder.setMaxTokens(maxTokens)
      optionsBuilder.setMaxTopK(topK)
      optionsBuilder.setPreferredBackend(resolveTasksGenaiBackend(preferredBackend))

      llmInference = LlmInference.createFromOptions(context, optionsBuilder.build())
      loadedRuntime = LoadedRuntime.TASKS_GENAI
      loadedModelPath = modelPath

      mapOf(
        "modelPath" to modelPath,
        "backend" to (preferredBackend ?: "default").lowercase(),
      )
    }

    AsyncFunction("generateResponseAsync") { prompt: String ->
      when (loadedRuntime) {
        LoadedRuntime.LITERT_LM -> generateWithLiteRtLm(prompt)
        LoadedRuntime.TASKS_GENAI -> generateWithTasksGenai(prompt)
        null -> throw IllegalStateException("No LiteRT model loaded.")
      }
    }

    AsyncFunction("generateAudioResponseAsync") { audioPath: String, prompt: String ->
      when (loadedRuntime) {
        LoadedRuntime.LITERT_LM -> generateWithLiteRtLmAudio(audioPath, prompt)
        LoadedRuntime.TASKS_GENAI ->
          throw IllegalStateException("Audio Scribe is only available with LiteRT-LM audio-capable models.")
        null -> throw IllegalStateException("No LiteRT model loaded.")
      }
    }

    AsyncFunction("cancelGenerateResponseAsync") {
      activeConversation?.cancelProcess()
      activeSession?.cancelGenerateResponseAsync()
      closeActiveConversation()
      closeActiveSession()
      null
    }

    AsyncFunction("unloadModelAsync") {
      unloadInternal()
      null
    }

    OnDestroy {
      unloadInternal()
    }
  }

  private fun isLiteRtLmModelPath(modelPath: String): Boolean {
    return modelPath.endsWith(".litertlm")
  }

  private fun defaultBackendName(modelPath: String): String {
    return if (isLiteRtLmModelPath(modelPath)) "gpu" else "default"
  }

  private fun isEnginePrepared(): Boolean {
    return when (loadedRuntime) {
      LoadedRuntime.LITERT_LM -> litertLmEngine?.isInitialized() == true
      LoadedRuntime.TASKS_GENAI -> llmInference != null
      null -> false
    }
  }

  private fun resolveTasksGenaiBackend(preferredBackend: String?): TasksGenaiBackend {
    return when (preferredBackend?.uppercase()) {
      "GPU" -> TasksGenaiBackend.GPU
      "CPU" -> TasksGenaiBackend.CPU
      else -> TasksGenaiBackend.DEFAULT
    }
  }

  private fun resolveLiteRtLmBackend(preferredBackend: String?): LiteRtLmBackend {
    return when (preferredBackend?.uppercase()) {
      "CPU" -> LiteRtLmBackend.CPU()
      "GPU", "DEFAULT", null -> LiteRtLmBackend.GPU()
      else -> LiteRtLmBackend.GPU()
    }
  }

  private fun buildSamplerConfig(): SamplerConfig {
    return SamplerConfig(
      generationTopK,
      generationTopP,
      generationTemperature.toDouble(),
      0,
    )
  }

  private fun generateWithTasksGenai(prompt: String): String {
    val inference = llmInference ?: throw IllegalStateException("No LiteRT model loaded.")
    closeActiveSession()

    val sessionOptions = LlmInferenceSession.LlmInferenceSessionOptions.builder()
      .setTopK(generationTopK)
      .setTemperature(generationTemperature)
      .build()
    val session = LlmInferenceSession.createFromOptions(inference, sessionOptions)
    activeSession = session
    session.addQueryChunk(prompt)

    var lastProgressText = ""
    try {
      val future = session.generateResponseAsync { partialText, done ->
        val delta =
          if (partialText.startsWith(lastProgressText)) {
            partialText.removePrefix(lastProgressText)
          } else {
            partialText
          }
        lastProgressText = partialText
        if (delta.isNotEmpty() || done) {
          sendEvent(
            "onToken",
            mapOf("text" to partialText, "delta" to delta, "done" to done),
          )
        }
      }
      future.get()
    } catch (error: ExecutionException) {
      throw IllegalStateException(error.cause?.message ?: error.message ?: "LiteRT generation failed.")
    } catch (_: CancellationException) {
      throw IllegalStateException("LiteRT generation was cancelled.")
    } finally {
      if (activeSession === session) {
        activeSession = null
      }
      session.close()
    }

    return lastProgressText
  }

  private fun generateWithLiteRtLm(prompt: String): String {
    val engine = litertLmEngine ?: throw IllegalStateException("No LiteRT-LM engine loaded.")
    closeActiveConversation()

    val conversation = engine.createConversation(
      ConversationConfig(
        Contents.Companion.of(""),
      ),
    )
    activeConversation = conversation

    val doneSignal = CountDownLatch(1)
    val accumulated = StringBuilder()
    val errorRef = AtomicReference<Throwable?>(null)

    conversation.sendMessageAsync(
      prompt,
      object : MessageCallback {
        override fun onMessage(message: Message) {
          val delta = message.toString()
          if (delta.isEmpty()) {
            return
          }
          accumulated.append(delta)
          sendEvent(
            "onToken",
            mapOf("text" to accumulated.toString(), "delta" to delta, "done" to false),
          )
        }

        override fun onDone() {
          sendEvent(
            "onToken",
            mapOf("text" to accumulated.toString(), "delta" to "", "done" to true),
          )
          doneSignal.countDown()
        }

        override fun onError(throwable: Throwable) {
          errorRef.set(throwable)
          doneSignal.countDown()
        }
      },
    )

    doneSignal.await()

    try {
      val error = errorRef.get()
      if (error != null) {
        if (error is CancellationException) {
          throw IllegalStateException("LiteRT generation was cancelled.")
        }
        throw IllegalStateException(error.message ?: "LiteRT-LM generation failed.")
      }
      return accumulated.toString()
    } finally {
      if (activeConversation === conversation) {
        activeConversation = null
      }
      conversation.close()
    }
  }

  private fun generateWithLiteRtLmAudio(audioPath: String, prompt: String): String {
    val engine = litertLmEngine ?: throw IllegalStateException("No LiteRT-LM engine loaded.")
    val audioFile = File(audioPath)
    if (!audioFile.exists()) {
      throw IllegalStateException("Audio file is missing at $audioPath")
    }
    val context = appContext.reactContext ?: throw Exceptions.ReactContextLost()

    val audioInputFile =
      if (audioFile.extension.equals("wav", ignoreCase = true)) {
        audioFile
      } else {
        transcodeAudioToWavFile(audioFile, context.cacheDir)
      }

    closeActiveConversation()

    val conversation = engine.createConversation(
      ConversationConfig(
        Contents.Companion.of(""),
      ),
    )
    activeConversation = conversation

    val doneSignal = CountDownLatch(1)
    val accumulated = StringBuilder()
    val errorRef = AtomicReference<Throwable?>(null)
    val contents =
      if (prompt.isBlank()) {
        Contents.Companion.of(Content.AudioFile(audioInputFile.absolutePath))
      } else {
        Contents.Companion.of(
          listOf(
            Content.AudioFile(audioInputFile.absolutePath),
            Content.Text(prompt),
          ),
        )
      }

    conversation.sendMessageAsync(
      contents,
      object : MessageCallback {
        override fun onMessage(message: Message) {
          val delta = message.toString()
          if (delta.isEmpty()) {
            return
          }
          accumulated.append(delta)
          sendEvent(
            "onToken",
            mapOf("text" to accumulated.toString(), "delta" to delta, "done" to false),
          )
        }

        override fun onDone() {
          sendEvent(
            "onToken",
            mapOf("text" to accumulated.toString(), "delta" to "", "done" to true),
          )
          doneSignal.countDown()
        }

        override fun onError(throwable: Throwable) {
          errorRef.set(throwable)
          doneSignal.countDown()
        }
      },
    )

    doneSignal.await()

    try {
      val error = errorRef.get()
      if (error != null) {
        if (error is CancellationException) {
          throw IllegalStateException("LiteRT generation was cancelled.")
        }
        throw IllegalStateException(error.message ?: "LiteRT-LM audio generation failed.")
      }
      return accumulated.toString()
    } finally {
      if (activeConversation === conversation) {
        activeConversation = null
      }
      conversation.close()
      if (audioInputFile != audioFile) {
        audioInputFile.delete()
      }
    }
  }

  private fun transcodeAudioToWavFile(audioFile: File, cacheDir: File): File {
    val extractor = MediaExtractor()
    var codec: MediaCodec? = null
    var outputFile: File? = null
    try {
      extractor.setDataSource(audioFile.absolutePath)

      val audioTrackIndex = (0 until extractor.trackCount).firstOrNull { index ->
        extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
      } ?: throw IllegalStateException("No audio track was found in ${audioFile.absolutePath}.")

      extractor.selectTrack(audioTrackIndex)
      val inputFormat = extractor.getTrackFormat(audioTrackIndex)
      val mime = inputFormat.getString(MediaFormat.KEY_MIME)
        ?: throw IllegalStateException("The audio file type is unsupported: ${audioFile.absolutePath}")
      var outputSampleRate =
        if (inputFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
          inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        } else {
          44100
        }
      var outputChannels =
        if (inputFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
          inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        } else {
          1
        }

      codec = MediaCodec.createDecoderByType(mime)
      codec.configure(inputFormat, null, null, 0)
      codec.start()

      outputFile = File.createTempFile("offlineaid-audio-", ".wav", cacheDir)
      var pcmBytesWritten = 0L
      var outputStream: FileOutputStream? = null
      try {
        outputStream = FileOutputStream(outputFile)
        writeWavHeader(outputStream, outputChannels, outputSampleRate, 16, 0)

        val bufferInfo = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false

        while (!outputDone) {
          if (!inputDone) {
            val inputIndex = codec.dequeueInputBuffer(10_000L)
            if (inputIndex >= 0) {
              val inputBuffer = codec.getInputBuffer(inputIndex)
                ?: throw IllegalStateException("Could not read audio input buffer.")
              val sampleSize = extractor.readSampleData(inputBuffer, 0)
              if (sampleSize < 0) {
                codec.queueInputBuffer(
                  inputIndex,
                  0,
                  0,
                  0,
                  MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                )
                inputDone = true
              } else {
                codec.queueInputBuffer(
                  inputIndex,
                  0,
                  sampleSize,
                  extractor.sampleTime,
                  0,
                )
                extractor.advance()
              }
            }
          }

          val outputIndex = codec.dequeueOutputBuffer(bufferInfo, 10_000L)
          when {
            outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
              val outputFormat = codec.outputFormat
              if (outputFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                outputSampleRate = outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
              }
              if (outputFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                outputChannels = outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
              }
            }

            outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
              if (inputDone) {
                continue
              }
            }

            outputIndex >= 0 -> {
              val outputBuffer = codec.getOutputBuffer(outputIndex)
                ?: throw IllegalStateException("Could not read decoded audio output.")
              if (bufferInfo.size > 0) {
                val chunk = ByteArray(bufferInfo.size)
                outputBuffer.position(bufferInfo.offset)
                outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                outputBuffer.get(chunk)
                outputStream.write(chunk)
                pcmBytesWritten += chunk.size.toLong()
              }
              codec.releaseOutputBuffer(outputIndex, false)
              if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                outputDone = true
              }
            }

            else -> {
              throw IllegalStateException("Audio decoding failed while preparing LiteRT-LM input.")
            }
          }
        }

        outputStream.flush()
        outputStream.close()
        outputStream = null
        rewriteWavHeader(outputFile, outputChannels, outputSampleRate, 16, pcmBytesWritten)
        return outputFile
      } finally {
        outputStream?.close()
      }
    } catch (error: Throwable) {
      outputFile?.delete()
      throw IllegalStateException(
        error.message ?: "Audio Scribe could not decode the recording for LiteRT-LM."
      )
    } finally {
      codec?.stop()
      codec?.release()
      extractor.release()
    }
  }

  private fun writeWavHeader(
    outputStream: FileOutputStream,
    channels: Int,
    sampleRate: Int,
    bitsPerSample: Int,
    pcmBytes: Long,
  ) {
    outputStream.write(wavHeaderBytes(channels, sampleRate, bitsPerSample, pcmBytes))
  }

  private fun rewriteWavHeader(
    wavFile: File,
    channels: Int,
    sampleRate: Int,
    bitsPerSample: Int,
    pcmBytes: Long,
  ) {
    RandomAccessFile(wavFile, "rw").use { raf ->
      raf.seek(0)
      raf.write(wavHeaderBytes(channels, sampleRate, bitsPerSample, pcmBytes))
    }
  }

  private fun wavHeaderBytes(
    channels: Int,
    sampleRate: Int,
    bitsPerSample: Int,
    pcmBytes: Long,
  ): ByteArray {
    val byteRate = sampleRate * channels * bitsPerSample / 8
    val blockAlign = channels * bitsPerSample / 8
    val dataSize = pcmBytes.toInt()
    val chunkSize = 36 + dataSize
    return ByteBuffer.allocate(44)
      .order(ByteOrder.LITTLE_ENDIAN)
      .apply {
        put("RIFF".toByteArray(Charsets.US_ASCII))
        putInt(chunkSize)
        put("WAVE".toByteArray(Charsets.US_ASCII))
        put("fmt ".toByteArray(Charsets.US_ASCII))
        putInt(16)
        putShort(1.toShort())
        putShort(channels.toShort())
        putInt(sampleRate)
        putInt(byteRate)
        putShort(blockAlign.toShort())
        putShort(bitsPerSample.toShort())
        put("data".toByteArray(Charsets.US_ASCII))
        putInt(dataSize)
      }
      .array()
  }

  private fun closeActiveConversation() {
    activeConversation?.close()
    activeConversation = null
  }

  private fun closeActiveSession() {
    activeSession?.close()
    activeSession = null
  }

  private fun unloadInternal() {
    closeActiveConversation()
    closeActiveSession()
    litertLmEngine?.close()
    litertLmEngine = null
    llmInference?.close()
    llmInference = null
    loadedModelPath = null
    loadedRuntime = null
  }
}
