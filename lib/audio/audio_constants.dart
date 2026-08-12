const int inputSampleRateHz = 16000;
const int outputSampleRateHz = 24000;
const int channelCount = 1;
const int bytesPerSample = 2;
const int inputChunkDurationMilliseconds = 100;
const Duration inputChunkDuration = Duration(milliseconds: 100);
const int inputChunkBytes =
    inputSampleRateHz * bytesPerSample * inputChunkDurationMilliseconds ~/ 1000;
