// Side-by-side Xbox diagnostic host. GPL-2.0-or-later.
#include "isolation.h"
#include <windows.h>
#include <roapi.h>
#include <cstdio>
#include <cwchar>
#include <atomic>
#include <chrono>
#include <exception>
#include <mutex>
#include <string>
#include <thread>

using namespace Platform;
using namespace Windows::ApplicationModel;
using namespace Windows::ApplicationModel::Core;
using namespace Windows::Foundation;
using namespace Windows::Storage;
using namespace Windows::System::Profile;
using namespace Windows::UI::Core;
using namespace Windows::UI::Popups;

namespace {
struct State
{
	std::mutex logMutex;
	FILE* log = nullptr;
	std::thread worker;
	std::atomic<bool> closing{false};
	const char* mode = "host";

	~State()
	{
		closing = true;
		if (worker.joinable()) worker.join();
		if (log) std::fclose(log);
	}
} state;

struct WorkerApartment
{
	HRESULT result = RoInitialize(RO_INIT_MULTITHREADED);
	~WorkerApartment() { if (SUCCEEDED(result)) RoUninitialize(); }
};

std::string Utf8(String^ value)
{
	const int count = WideCharToMultiByte(CP_UTF8, 0, value->Data(), value->Length(), nullptr, 0, nullptr, nullptr);
	std::string out(static_cast<size_t>(count), '\0');
	if (count) WideCharToMultiByte(CP_UTF8, 0, value->Data(), value->Length(), &out[0], count, nullptr, nullptr);
	return out;
}

void Log(void*, const char* line)
{
	std::lock_guard<std::mutex> lock(state.logMutex);
	if (state.log)
	{
		std::fprintf(state.log, "mode=%s %s\n", state.mode, line);
		std::fflush(state.log); // Keep every completed observation recoverable after termination.
	}
}

double CpuSeconds()
{
	FILETIME created{}, exited{}, kernel{}, user{};
	if (!GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user)) return -1;
	ULARGE_INTEGER k{}, u{};
	k.LowPart = kernel.dwLowDateTime; k.HighPart = kernel.dwHighDateTime;
	u.LowPart = user.dwLowDateTime; u.HighPart = user.dwHighDateTime;
	return double(k.QuadPart + u.QuadPart) / 10000000.0;
}
}

namespace RingRacersD3D12Isolation {
// Window/dialog members are confined to the view's UI thread. Background
// callbacks use a captured agile dispatcher to post work before accessing them.
ref class View sealed : public IFrameworkView
{
private:
	CoreWindow^ window_;
	IAsyncOperation<IUICommand^>^ startingDialog_;
	String^ finalSummary_;
	bool started_ = false;
	bool finalShown_ = false;

	void ExitProcess()
	{
		state.closing = true;
		if (state.worker.joinable()) state.worker.join();
		CoreApplication::Exit();
	}

	void ShowFinal()
	{
		if (finalShown_ || !finalSummary_ || state.closing) return;
		finalShown_ = true;
		auto dispatcher = window_->Dispatcher;
		auto finished = (ref new MessageDialog(finalSummary_, "D3D12 experiment complete"))->ShowAsync();
		finished->Completed = ref new AsyncOperationCompletedHandler<IUICommand^>(
			[this, dispatcher](IAsyncOperation<IUICommand^>^, AsyncStatus) {
				dispatcher->RunAsync(CoreDispatcherPriority::Normal, ref new DispatchedHandler([this] { ExitProcess(); }));
			});
	}

	void StartExperiment(rrdiag::Experiment experiment, const char* name)
	{
		// UI thread fixes the mode before starting the worker; no writer changes it
		// until the core (including its watchdog) has returned.
		state.mode = name;
		char selection[256];
		std::snprintf(selection, sizeof(selection), "SESSION_SELECTION experiment=%s dred=%s oneExperimentPerProcess=1", name,
			experiment == rrdiag::Experiment::Memory ? "forced-off" : "untouched");
		Log(nullptr, selection);
		auto dispatcher = window_->Dispatcher;
		state.worker = std::thread([this, dispatcher, experiment] {
			WorkerApartment apartment;
			const auto start = std::chrono::steady_clock::now();
			const auto cpuStart = CpuSeconds();
			rrdiag::Result result;
			bool ran = false;
			bool failed = FAILED(apartment.result);
			if (failed)
			{
				char error[128];
				std::snprintf(error, sizeof(error), "HOST_WORKER_INIT_FAILED hr=0x%08lx testsSkipped=1", static_cast<unsigned long>(apartment.result));
				Log(nullptr, error);
			}
			try
			{
				if (!state.closing && SUCCEEDED(apartment.result))
				{
					rrdiag::Options options;
					options.experiment = experiment;
					if (experiment == rrdiag::Experiment::Memory)
					{
						options.dredExplicit = true;
						options.dredEnabled = false;
					}
					result = rrdiag::Run(options, Log, nullptr);
					ran = true;
					failed |= result.deviceFailed || result.debugErrors || result.sehStages || result.stagesIncomplete;
				}
			}
			catch (const std::exception& error) { failed = true; Log(nullptr, error.what()); }
			catch (...) { failed = true; Log(nullptr, "HOST_EXCEPTION unknown"); }
			const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
			const double cpuEnd = CpuSeconds();
			const double cpu = cpuStart < 0 || cpuEnd < 0 ? -1 : cpuEnd - cpuStart;
			const unsigned copyFailures = result.copyOrderFailures[0] + result.copyOrderFailures[1] +
				result.copyOrderFailures[2] + result.copyOrderFailures[3];
			const bool detected = result.reproFailures || result.mapCasesWithOutsideWrites || result.committedCpuChanged ||
				result.committedDefaultChanged || result.uploadSourceDamaged || copyFailures;
			char summary[1024];
			std::snprintf(summary, sizeof(summary), "SESSION_END pid=%lu experiment=%s ran=%u sehStages=%u stagesIncomplete=%u probesCompleted=%u watchdogReports=%u reproFailures=%u mapCasesRun=%u mapCasesWithOutsideWrites=%u unavailable=%u committedCpuChanged=%u committedDefaultChanged=%u uploadSourceDamaged=%u defaultControlsCompleted=%u copyOrderFailures=%u/%u/%u/%u selfTestsFailed=%u deviceFailed=%u debugErrors=%u failed=%u closed=%u wallSeconds=%.3f cpuSeconds=%.3f",
				static_cast<unsigned long>(GetCurrentProcessId()), state.mode, ran ? 1u : 0u, result.sehStages, result.stagesIncomplete, result.probesCompleted, result.watchdogReports, result.reproFailures, result.mapCasesRun, result.mapCasesWithOutsideWrites, result.unavailableCases,
				result.committedCpuChanged, result.committedDefaultChanged, result.uploadSourceDamaged, result.defaultControlsCompleted, result.copyOrderFailures[0], result.copyOrderFailures[1],
				result.copyOrderFailures[2], result.copyOrderFailures[3], result.selfTestsFailed, result.deviceFailed ? 1u : 0u,
				result.debugErrors ? 1u : 0u, failed ? 1u : 0u, state.closing ? 1u : 0u, elapsed, cpu);
			Log(nullptr, summary);
			if (!state.closing && SUCCEEDED(apartment.result))
			{
				std::wstring text = (failed || result.selfTestsFailed) ? L"The experiment stopped with an error. " :
					(detected ? L"The experiment detected changed memory. " : L"The experiment completed without detected memory changes. ");
				text += L"Captured exceptions: " + std::to_wstring(result.sehStages) +
					L". Unavailable: " + std::to_wstring(result.unavailableCases) +
					L". Results have been appended to placement-isolation-log.txt in LocalState. Acknowledge to close this process. Launch the app again to choose the next experiment; collect the one log after all three choices.";
				auto completeText = ref new String(text.c_str());
				dispatcher->RunAsync(CoreDispatcherPriority::Normal, ref new DispatchedHandler([this, completeText] {
					if (state.closing) return;
					finalSummary_ = completeText;
					ShowFinal();
				}));
			}
			else if (!state.closing)
			{
				// Failed RoInitialize cannot safely dispatch; let the UI loop close.
				state.closing = true;
			}
		});
	}

	void Activated(CoreApplicationView^, Windows::ApplicationModel::Activation::IActivatedEventArgs^)
	{
		window_->Activate();
		if (started_) return;
		started_ = true;
		const auto version = Package::Current->Id->Version;
		const auto diagnosticVersion = ref new String((std::to_wstring(version.Major) + L"." + std::to_wstring(version.Minor) +
			L"." + std::to_wstring(version.Build) + L"." + std::to_wstring(version.Revision)).c_str());
		auto settings = ApplicationData::Current->LocalSettings->Values;
		auto previousVersion = settings->HasKey("IsolationLogVersion") ? dynamic_cast<String^>(settings->Lookup("IsolationLogVersion")) : nullptr;
		const bool clearLog = !previousVersion || std::wcscmp(previousVersion->Data(), diagnosticVersion->Data()) != 0;
		std::wstring path(ApplicationData::Current->LocalFolder->Path->Data());
		path += L"\\placement-isolation-log.txt";
		if (_wfopen_s(&state.log, path.c_str(), clearLog ? L"wb" : L"ab") != 0 || !state.log)
		{
			finalSummary_ = "The experiment could not open its log in LocalState. No tests ran. Acknowledge to close the app.";
			ShowFinal();
			return;
		}
		settings->Insert("IsolationLogVersion", diagnosticVersion);
		const auto osVersion = _wcstoui64(AnalyticsInfo::VersionInfo->DeviceFamilyVersion->Data(), nullptr, 10);
		char metadata[640];
		std::snprintf(metadata, sizeof(metadata), "SESSION_BEGIN pid=%lu experiment=pending package=RingRacersD3D12Isolation version=%u.%u.%u.%u logCleared=%u deviceFamily=%s familyVersion=%s osVersion=%llu.%llu.%llu.%llu",
			static_cast<unsigned long>(GetCurrentProcessId()), static_cast<unsigned>(version.Major), static_cast<unsigned>(version.Minor), static_cast<unsigned>(version.Build), static_cast<unsigned>(version.Revision), clearLog ? 1u : 0u,
			Utf8(AnalyticsInfo::VersionInfo->DeviceFamily).c_str(), Utf8(AnalyticsInfo::VersionInfo->DeviceFamilyVersion).c_str(),
			(osVersion >> 48) & 0xffff, (osVersion >> 32) & 0xffff, (osVersion >> 16) & 0xffff, osVersion & 0xffff);
		Log(nullptr, metadata);
		auto dialog = ref new MessageDialog("Choose one experiment. This launch runs only your selection, then closes. Launch again for the other two choices; their results append to the same LocalState log.", "D3D12 isolation experiment");
		dialog->Commands->Append(ref new UICommand("Crash details"));
		dialog->Commands->Append(ref new UICommand("Copy ordering"));
		dialog->Commands->Append(ref new UICommand("Texture memory"));
		auto dispatcher = window_->Dispatcher;
		startingDialog_ = dialog->ShowAsync();
		startingDialog_->Completed = ref new AsyncOperationCompletedHandler<IUICommand^>(
			[this, dispatcher](IAsyncOperation<IUICommand^>^ operation, AsyncStatus status) {
				dispatcher->RunAsync(CoreDispatcherPriority::Normal, ref new DispatchedHandler([this, operation, status] {
					if (state.closing) return;
					if (status != AsyncStatus::Completed)
					{
						Log(nullptr, "SESSION_END experiment=none ran=0 status=selection-canceled");
						ExitProcess();
						return;
					}
					auto selected = operation->GetResults();
					if (!selected)
					{
						Log(nullptr, "SESSION_END experiment=none ran=0 status=selection-canceled");
						ExitProcess();
					}
					else if (std::wcscmp(selected->Label->Data(), L"Crash details") == 0) StartExperiment(rrdiag::Experiment::Crash, "crash");
					else if (std::wcscmp(selected->Label->Data(), L"Copy ordering") == 0) StartExperiment(rrdiag::Experiment::Copy, "copy");
					else if (std::wcscmp(selected->Label->Data(), L"Texture memory") == 0) StartExperiment(rrdiag::Experiment::Memory, "memory");
					else ExitProcess();
				}));
			});
	}

public:
	virtual void Initialize(CoreApplicationView^ view)
	{
		view->Activated += ref new TypedEventHandler<CoreApplicationView^, Windows::ApplicationModel::Activation::IActivatedEventArgs^>(this, &View::Activated);
	}
	virtual void SetWindow(CoreWindow^ window)
	{
		window_ = window;
		window_->Closed += ref new TypedEventHandler<CoreWindow^, CoreWindowEventArgs^>(
			[](CoreWindow^, CoreWindowEventArgs^) { state.closing = true; });
	}
	virtual void Load(String^) {}
	virtual void Run()
	{
		while (!state.closing)
		{
			// A worker whose RoInitialize failed cannot call a WinRT dispatcher.
			// Bounded polling still observes its atomic closing flag and exits.
			window_->Dispatcher->ProcessEvents(CoreProcessEventsOption::ProcessAllIfPresent);
			std::this_thread::sleep_for(std::chrono::milliseconds(20));
		}
		if (state.worker.joinable()) state.worker.join(); // Run has finite cases and bounded GPU waits.
	}
	virtual void Uninitialize() {}
};

ref class Source sealed : public IFrameworkViewSource
{
public:
	virtual IFrameworkView^ CreateView() { return ref new View(); }
};
}

[MTAThread]
int main(Array<String^>^)
{
	CoreApplication::Run(ref new RingRacersD3D12Isolation::Source());
	return 0;
}
