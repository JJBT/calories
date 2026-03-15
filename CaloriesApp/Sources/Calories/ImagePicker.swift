import PhotosUI
import SwiftUI

struct MultiImagePicker: UIViewControllerRepresentable {
    var maxSelection: Int = 6
    var onPicked: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = maxSelection
        config.filter = .images
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([UIImage]) -> Void
        init(onPicked: @escaping ([UIImage]) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { onPicked([]); return }

            var images: [UIImage] = []
            let group = DispatchGroup()

            for r in results {
                if r.itemProvider.canLoadObject(ofClass: UIImage.self) {
                    group.enter()
                    r.itemProvider.loadObject(ofClass: UIImage.self) { obj, _ in
                        if let img = obj as? UIImage { images.append(img) }
                        group.leave()
                    }
                }
            }

            group.notify(queue: .main) {
                self.onPicked(images)
            }
        }
    }
}

struct CameraImagePicker: UIViewControllerRepresentable {
    var onPicked: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        if picker.sourceType == .camera {
            picker.cameraCaptureMode = .photo
            if UIImagePickerController.isCameraDeviceAvailable(.rear) {
                picker.cameraDevice = .rear
            }
            if UIImagePickerController.isFlashAvailable(for: .rear) {
                picker.cameraFlashMode = .auto
            }
        }
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onPicked: (UIImage?) -> Void

        init(onPicked: @escaping (UIImage?) -> Void) {
            self.onPicked = onPicked
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            onPicked(nil)
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            picker.dismiss(animated: true)
            onPicked(image)
        }
    }
}
