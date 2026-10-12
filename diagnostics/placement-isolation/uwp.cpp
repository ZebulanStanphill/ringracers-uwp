// Side-by-side Xbox diagnostic host. GPL-2.0-or-later.
#include "isolation.h"
#include <windows.h>
#include <roapi.h>
#include <cstdio>
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

	void ShowFinal()
	{
		if (finalShown_ || !finalSummary_ || state.closing) return;
		finalShown_ = true;
		(ref new MessageDialog(finalSummary_, "D3D12 isolation test complete"))->ShowAsync();
	}

	void Activated(CoreApplicationView^, Windows::ApplicationModel::Activation::IActivatedEventArgs^)
	{
		window_->Activate();
		if (started_) return;
		started_ = true;
		std::wstring path(ApplicationData::Current->LocalFolder->Path->Data());
		path += L"\\placement-isolation-log.txt";
		if (_wfopen_s(&state.log, path.c_str(), L"wb") != 0 || !state.log)
		{
			finalSummary_ = "The test could not open its log in LocalState. No tests ran.";
			ShowFinal();
			return;
		}

		const auto version = Package::Current->Id->Version;
		const auto osVersion = _wcstoui64(AnalyticsInfo::VersionInfo->DeviceFamilyVersion->Data(), nullptr, 10);
		char metadata[512];
		std::snprintf(metadata, sizeof(metadata), "HOST package=RingRacersD3D12Isolation version=%u.%u.%u.%u deviceFamily=%s familyVersion=%s osVersion=%llu.%llu.%llu.%llu",
			static_cast<unsigned>(version.Major), static_cast<unsigned>(version.Minor), static_cast<unsigned>(version.Build), static_cast<unsigned>(version.Revision),
			Utf8(AnalyticsInfo::VersionInfo->DeviceFamily).c_str(), Utf8(AnalyticsInfo::VersionInfo->DeviceFamilyVersion).c_str(),
			(osVersion >> 48) & 0xffff, (osVersion >> 32) & 0xffff, (osVersion >> 16) & 0xffff, osVersion & 0xffff);
		Log(nullptr, metadata);
		Log(nullptr, "HOST log=LocalState/placement-isolation-log.txt automatic=1 dredModes=off,on repeats=2");

		auto dialog = ref new MessageDialog(
			"The D3D12 memory isolation tests are running automatically. Leave this app open until the completion message appears. "
			"Results are written to placement-isolation-log.txt in this app's LocalState folder.",
			"D3D12 isolation test running");
		auto dispatcher = window_->Dispatcher;
		startingDialog_ = dialog->ShowAsync();
		startingDialog_->Completed = ref new AsyncOperationCompletedHandler<IUICommand^>(
			[this, dispatcher](IAsyncOperation<IUICommand^>^, AsyncStatus) {
				if (!state.closing)
					dispatcher->RunAsync(CoreDispatcherPriority::Normal, ref new DispatchedHandler([this] { ShowFinal(); }));
			});

		state.worker = std::thread([this, dispatcher] {
			WorkerApartment apartment;
			const auto start = std::chrono::steady_clock::now();
			const auto cpuStart = CpuSeconds();
			unsigned cases = 0, mismatches = 0, unavailable = 0, selfTestsFailed = 0;
			bool failed = FAILED(apartment.result);
			if (failed)
			{
				char error[128];
				std::snprintf(error, sizeof(error), "HOST_WORKER_INIT_FAILED hr=0x%08lx testsSkipped=1", static_cast<unsigned long>(apartment.result));
				Log(nullptr, error);
			}
			try
			{
				for (unsigned mode = 0; mode != 2 && !state.closing && SUCCEEDED(apartment.result); ++mode)
				{
					state.mode = mode ? "dred-on" : "dred-off";
					rrdiag::Options options;
					options.dredEnabled = mode != 0;
					const rrdiag::Result result = rrdiag::Run(options, Log, nullptr);
					cases += result.casesCompleted;
					mismatches += result.mismatchCases;
					unavailable += result.unavailableCases;
					selfTestsFailed += result.selfTestsFailed;
					failed |= result.deviceFailed || result.debugErrors || !result.casesCompleted;
					if (result.deviceFailed)
					{
						Log(nullptr, "HOST_MODE_STOP priorDeviceFailure=1 remainingModesSkipped=1 restartRequired=1");
						break; // A timed-out device intentionally retains resources until process exit.
					}
				}
			}
			catch (const std::exception& error)
			{
				failed = true;
				Log(nullptr, error.what());
			}
			catch (...)
			{
				failed = true;
				Log(nullptr, "HOST_EXCEPTION unknown");
			}
			state.mode = "host";
			const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
			const double cpuEnd = CpuSeconds();
			const double cpu = cpuStart < 0 || cpuEnd < 0 ? -1 : cpuEnd - cpuStart;
			char summary[512];
			std::snprintf(summary, sizeof(summary), "HOST_FINISHED cases=%u mismatches=%u unavailable=%u selfTestsFailed=%u failed=%u closed=%u wallSeconds=%.3f cpuSeconds=%.3f",
				cases, mismatches, unavailable, selfTestsFailed, failed ? 1 : 0, state.closing ? 1 : 0, elapsed, cpu);
			Log(nullptr, summary);
			if (!state.closing && SUCCEEDED(apartment.result))
			{
				std::wstring text = (failed || selfTestsFailed) ? L"The tests finished with an error. " :
					(mismatches ? L"The tests detected changed memory. " : L"The tests completed without detected memory changes. ");
				text += L"Cases: " + std::to_wstring(cases) + L". Mismatch cases: " + std::to_wstring(mismatches) +
					L". Unavailable cases: " + std::to_wstring(unavailable) +
					L". Retrieve placement-isolation-log.txt from this app's LocalState folder using Xbox Device Portal. You may now close the app.";
				auto completeText = ref new String(text.c_str());
				dispatcher->RunAsync(CoreDispatcherPriority::Normal, ref new DispatchedHandler([this, completeText] {
					if (state.closing) return;
					finalSummary_ = completeText;
					if (startingDialog_->Status == AsyncStatus::Started) startingDialog_->Cancel();
					else ShowFinal();
				}));
			}
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
			window_->Dispatcher->ProcessEvents(CoreProcessEventsOption::ProcessOneAndAllPending);
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
