import 'lib/system_actions_service.dart';
void main() async {
  try {
    final apps = await SystemActionsService.getInstalledApps();
    print("APPS_COUNT=" + apps.length.toString());
  } catch(e, st) {
    print("Error: $e");
    print(st);
  }
}
