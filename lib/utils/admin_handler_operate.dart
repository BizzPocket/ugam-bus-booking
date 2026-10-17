import 'package:easy_localization/easy_localization.dart';
import 'package:get/get.dart';

import '../models/tour.dart';
import '../models/tour_status.dart';
import '../screens/handler/handler_shell.dart';
import 'app_snackbar.dart';

/// Same gate as [is_request_handler] on the server: handler tools only after lock.
bool tourAllowsAdminHandlerOperate(TourStatus status) =>
    status == TourStatus.locked || status == TourStatus.completed;

/// Opens [HandlerShell] for the tour owner, scoped to [busId] via the admin
/// opaque ref (see migration 097).
void openAdminHandlerOperate({required Tour tour, required String busId}) {
  if (!tourAllowsAdminHandlerOperate(tour.status)) {
    AppSnackBar.warning(tr('admin_handler_operate.locked_only'));
    return;
  }
  Get.to(
    () => HandlerShell(
      requestId: busId,
      tourStatus: tour.status.name,
    ),
    transition: Transition.cupertino,
  );
}
