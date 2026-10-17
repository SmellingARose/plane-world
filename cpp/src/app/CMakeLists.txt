find_package(Qt6 6.8 REQUIRED COMPONENTS Quick QuickControls2)
qt_standard_project_setup(REQUIRES 6.8)

qt_add_executable(pwapp MACOSX_BUNDLE WIN32 main.cpp gpuviewport.cpp gpuviewport.h)
if(APPLE)
  target_sources(pwapp PRIVATE gpuviewport_metal.mm)
  set_source_files_properties(gpuviewport_metal.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
endif()
set_target_properties(pwapp PROPERTIES
  OUTPUT_NAME "Plane World"
  MACOSX_BUNDLE_GUI_IDENTIFIER org.planeworld.app
  MACOSX_BUNDLE_BUNDLE_NAME "Plane World"
  MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
  MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION})

set_source_files_properties(qml/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
qt_add_qml_module(pwapp
  URI PlaneWorld
  VERSION 1.0
  QML_FILES
    qml/Main.qml
    qml/Theme.qml
    qml/TabPage.qml
    qml/Inspector.qml
    qml/CommandPalette.qml
    qml/KeyHint.qml
    qml/ViewportHud.qml
)
target_link_libraries(pwapp PRIVATE Qt6::Quick Qt6::QuickControls2 pwcore pwgpu pwrender pwflow pwflow_render)

if(WIN32)
  # Deploy Qt next to the exe for CI artefacts (windeployqt from the same Qt install).
  get_target_property(_qmake Qt6::qmake IMPORTED_LOCATION)
  get_filename_component(_qtbin ${_qmake} DIRECTORY)
  find_program(PW_WINDEPLOYQT windeployqt HINTS ${_qtbin})
  if(PW_WINDEPLOYQT)
    # Self-contained folder: ${CMAKE_BINARY_DIR}/deploy/Plane World.exe + Qt runtime (no build intermediates).
    set(_dep ${CMAKE_BINARY_DIR}/deploy)
    add_custom_target(pwapp_deploy
      COMMAND ${CMAKE_COMMAND} -E rm -rf ${_dep}
      COMMAND ${CMAKE_COMMAND} -E make_directory ${_dep}
      COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:pwapp> ${_dep}/
      COMMAND ${PW_WINDEPLOYQT} --qmldir ${CMAKE_CURRENT_SOURCE_DIR}/qml --no-translations "${_dep}/$<TARGET_FILE_NAME:pwapp>"
      DEPENDS pwapp VERBATIM)
  endif()
elseif(APPLE)
  get_target_property(_qmake Qt6::qmake IMPORTED_LOCATION)
  get_filename_component(_qtbin ${_qmake} DIRECTORY)
  find_program(PW_MACDEPLOYQT macdeployqt HINTS ${_qtbin})
  if(PW_MACDEPLOYQT)
    add_custom_target(pwapp_deploy
      COMMAND ${PW_MACDEPLOYQT} $<TARGET_BUNDLE_DIR:pwapp> -qmldir=${CMAKE_CURRENT_SOURCE_DIR}/qml
      DEPENDS pwapp VERBATIM)
  endif()
endif()
