// Standalone host for the SDK-only placement isolation suite. GPL-2.0-or-later.
#include "isolation.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {
struct LogState
{
	unsigned sentinelChanges = 0;
	unsigned ownerChanges = 0;
	unsigned injections = 0;
	bool unexpectedCorruption = false;
	bool controlsDisagree = false;
	bool sentinelShaderWitness = false;
	bool sentinelCopyWitness = false;
	bool ownerShaderWitness = false;
	bool ownerCopyWitness = false;
	bool sentinelZero = false;
	bool ownerZero = false;
};

void Log(void* context, const char* line)
{
	std::puts(line);
	std::fflush(stdout);
	auto& state = *static_cast<LogState*>(context);
	if (std::strstr(line, "INJECTION target="))
		++state.injections;
	if (std::strstr(line, "OBSERVE target="))
	{
		state.controlsDisagree |= !std::strstr(line, "outputsEqual=1 ") ||
			!std::strstr(line, "remapEqual=1 ") || !std::strstr(line, "prefixTailChanges=0,0");
		const char* changed = std::strstr(line, "changed=");
		if (changed && std::strtoul(changed + 8, nullptr, 10) != 0)
		{
			const bool sentinel = std::strstr(line, "target=sentinel ") != nullptr;
			const bool owner = std::strstr(line, "target=owner ") != nullptr;
			if (sentinel) ++state.sentinelChanges;
			if (owner) ++state.ownerChanges;
			state.sentinelShaderWitness |= sentinel && std::strstr(line, "phase=injected-first-word method=shader ");
			state.sentinelCopyWitness |= sentinel && std::strstr(line, "phase=injected-first-word-copy-witness method=copy ");
			state.ownerShaderWitness |= owner && std::strstr(line, "phase=owner-shader-load method=shader ");
			state.ownerCopyWitness |= owner && std::strstr(line, "phase=owner-readback-exact-and-padded method=copy ");
			const char* first = std::strstr(line, "first=");
			const char* last = std::strstr(line, "last=");
			const unsigned long expectedIndex = sentinel ? 0 : 256 * 256 - 1;
			state.unexpectedCorruption |= !first || !last || (!sentinel && !owner) ||
				std::strtoul(changed + 8, nullptr, 10) != 1 ||
				(first && std::strtoul(first + 6, nullptr, 10) != expectedIndex) ||
				(last && std::strtoul(last + 5, nullptr, 10) != expectedIndex);
		}
	}
	if (std::strstr(line, "DIFFERENCE target=") && std::strstr(line, "first=00000000 second=00000000"))
	{
		state.sentinelZero |= std::strstr(line, "target=sentinel ") && std::strstr(line, " index=0 ");
		state.ownerZero |= std::strstr(line, "target=owner ") && std::strstr(line, " index=65535 ");
	}
}
}

int main(int argc, char** argv)
{
	rrdiag::Options options;
	bool reproOnly = false;
	for (int i = 1; i < argc; ++i)
	{
		if (!std::strcmp(argv[i], "--warp")) options.warp = true;
		else if (!std::strcmp(argv[i], "--quick")) options.quick = true;
		else if (!std::strcmp(argv[i], "--debug")) options.debug = true;
		else if (!std::strcmp(argv[i], "--gpu-validation")) options.gpuValidation = true;
		else if (!std::strcmp(argv[i], "--dred-on")) { options.dredEnabled = true; options.dredExplicit = true; }
		else if (!std::strcmp(argv[i], "--dred-off")) { options.dredEnabled = false; options.dredExplicit = true; }
		else if (!std::strcmp(argv[i], "--experiment") && i + 1 < argc)
		{
			const char* value = argv[++i];
			if (!std::strcmp(value, "all")) options.experiment = rrdiag::Experiment::All;
			else if (!std::strcmp(value, "crash")) options.experiment = rrdiag::Experiment::Crash;
			else if (!std::strcmp(value, "copy")) options.experiment = rrdiag::Experiment::Copy;
			else if (!std::strcmp(value, "memory")) options.experiment = rrdiag::Experiment::Memory;
			else if (!std::strcmp(value, "address")) options.experiment = rrdiag::Experiment::Address;
			else { std::fprintf(stderr, "Unknown experiment: %s\n", value); return 64; }
		}
		else if (!std::strcmp(argv[i], "--self-test-seh")) options.selfTestSeh = true;
		else if (!std::strcmp(argv[i], "--legacy-suite")) options.legacySuite = true;
		else if (!std::strcmp(argv[i], "--repro-only")) reproOnly = true;
		else if (!std::strcmp(argv[i], "--negative-map-outside")) options.injection = rrdiag::Injection::MapOutsideWord;
		else if (!std::strcmp(argv[i], "--negative-sentinel"))
		{
			options.injection = rrdiag::Injection::SentinelFirstWordZero;
			options.legacySuite = true;
		}
		else if (!std::strcmp(argv[i], "--negative-owner"))
		{
			options.injection = rrdiag::Injection::OwnerLastWordZero;
			options.legacySuite = true;
		}
		else if (!std::strcmp(argv[i], "--repeats") && i + 1 < argc)
		{
			char* end = nullptr;
			unsigned long value = std::strtoul(argv[++i], &end, 10);
			if (!value || value > 16 || *end) return 64;
			options.repeats = static_cast<unsigned>(value);
		}
		else
		{
			std::fprintf(stderr, "Unknown or incomplete argument: %s\n", argv[i]);
			return 64;
		}
	}

	LogState log;
	if (reproOnly)
	{
		// Just the self-contained minimal reproduction on its own device.
		rrdiag::ReproStatus status;
		const int failures = rrdiag::RunMinimalRepro(Log, &log, options.warp, &status);
		return failures || status.deviceFailed ? 1 : 0;
	}
	const rrdiag::Result result = rrdiag::Run(options, Log, &log);
	if (!options.legacySuite)
	{
		const unsigned copyFailures = result.copyOrderFailures[0] + result.copyOrderFailures[1] +
			result.copyOrderFailures[2] + result.copyOrderFailures[3];
		std::printf("HOST_RESULT reproFailures=%u mapCasesWithOutsideWrites=%u unavailable=%u committedCpuChanged=%u "
			"copyOrderFailures=%u/%u/%u/%u selfTestsFailed=%u deviceFailed=%u mapCasesRun=%u committedDefaultChanged=%u "
			"uploadSourceDamaged=%u injectionsAttempted=%u injectionsDetected=%u debugErrors=%u "
			"defaultControlsCompleted=%u sehStages=%u stagesIncomplete=%u probesCompleted=%u watchdogReports=%u "
			"addressCases=%u addressChangedWords=%u\n",
			result.reproFailures, result.mapCasesWithOutsideWrites, result.unavailableCases, result.committedCpuChanged,
			result.copyOrderFailures[0], result.copyOrderFailures[1], result.copyOrderFailures[2], result.copyOrderFailures[3],
			result.selfTestsFailed, result.deviceFailed ? 1 : 0, result.mapCasesRun, result.committedDefaultChanged,
			result.uploadSourceDamaged, result.injectionsAttempted, result.injectionsDetected, result.debugErrors ? 1 : 0,
			result.defaultControlsCompleted, result.sehStages, result.stagesIncomplete, result.probesCompleted, result.watchdogReports,
			result.addressCases, result.addressChangedWords);
		const bool clean = !result.deviceFailed && !result.debugErrors && !result.selfTestsFailed;
		if (options.injection == rrdiag::Injection::MapOutsideWord)
		{
			// Every map case was corrupted by the harness; each must be reported exactly once.
			if (clean && !result.reproFailures && !copyFailures && !result.committedCpuChanged && result.injectionsAttempted &&
				result.injectionsDetected == result.injectionsAttempted && result.mapCasesRun == result.injectionsAttempted &&
				result.mapCasesWithOutsideWrites == result.injectionsAttempted)
			{
				std::puts("NEGATIVE_ORACLE_REJECTED:isolation-map-outside");
				return 2;
			}
			std::puts("NEGATIVE_ORACLE_INVALID");
			return 3;
		}
		if (options.selfTestSeh)
		{
			// A caught exception poisons the process: no production stage may follow it.
			return clean && result.sehStages == 1 && result.stagesIncomplete == 1 && !result.probesCompleted &&
				!result.mapCasesRun && !result.reproFailures && !copyFailures && !result.watchdogReports ? 0 : 1;
		}
		// Hardware runs are expected to report the driver defect; WARP must be clean.
		return clean && !result.sehStages && !result.stagesIncomplete && !result.watchdogReports &&
			(options.experiment == rrdiag::Experiment::Crash ? result.probesCompleted == 1 :
			 options.experiment == rrdiag::Experiment::Copy ? true :
			 options.experiment == rrdiag::Experiment::Address ? result.addressCases >= 3 : result.mapCasesRun > 0 && result.defaultControlsCompleted == 1) && !result.reproFailures && !result.mapCasesWithOutsideWrites &&
			!result.committedCpuChanged && !result.committedDefaultChanged && !result.uploadSourceDamaged && !copyFailures ? 0 : 1;
	}
	std::printf("HOST_RESULT cases=%u mismatches=%u unavailable=%u selfTestsFailed=%u deviceFailed=%u debugErrors=%u\n",
		result.casesCompleted, result.mismatchCases, result.unavailableCases,
		result.selfTestsFailed, result.deviceFailed ? 1 : 0, result.debugErrors ? 1 : 0);
	const bool apiClean = !result.deviceFailed && !result.debugErrors && !result.selfTestsFailed;
	if (options.injection != rrdiag::Injection::None)
	{
		const bool sentinel = options.injection == rrdiag::Injection::SentinelFirstWordZero;
		const unsigned wanted = sentinel ? log.sentinelChanges : log.ownerChanges;
		const unsigned unwanted = sentinel ? log.ownerChanges : log.sentinelChanges;
		const bool witnesses = sentinel ? log.sentinelShaderWitness && log.sentinelCopyWitness && log.sentinelZero :
			log.ownerShaderWitness && log.ownerCopyWitness && log.ownerZero;
		if (apiClean && result.casesCompleted == 5 && result.mismatchCases == 1 && !result.unavailableCases &&
			log.injections == 1 && wanted && !unwanted && !log.unexpectedCorruption && !log.controlsDisagree && witnesses)
		{
			std::printf("NEGATIVE_ORACLE_REJECTED:%s\n", sentinel ? "isolation-sentinel" : "isolation-owner");
			return 2;
		}
		std::puts("NEGATIVE_ORACLE_INVALID");
		return 3;
	}
	return apiClean && result.casesCompleted && !result.mismatchCases ? 0 : 1;
}
