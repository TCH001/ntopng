$(document).ready(function () {

    function makeFormData(formSelector) {

        const $inputsTemplate = $(`${formSelector} .recipient-template-container [name]`);
        const params = {};
        $inputsTemplate.each(function(i, input){
            params[$(this).attr('name')] = $(this).val().trim();
        });

        params.recipient_name = $(`${formSelector} [name='name']`).val();
        params.endpoint_conf_name = $(`${formSelector} [name='endpoint']`).val();

        return params;
    }

    function createTemplateOnSelect(formSelector) {
        const $templateContainer = $(`${formSelector} .recipient-template-container`);
        $(`${formSelector} select[name='endpoint']`).change(function(e) {
            const $option = $(this).find(`option[value='${$(this).val()}']`);
            const template = $(`template#${$option.data('endpointKey')}-template`).html();
            const $cloned = $(template);
            $templateContainer.empty().append($cloned).fadeIn();
        });
    }

    function loadTemplate(type) {
        const template = $(`template#${type}-template`).html();
        return $(template);
    }

    const $recipientsTable = $(`table#recipient-list`).DataTable({
        lengthChange: false,
        pagingType: 'full_numbers',
        stateSave: true,
        dom: 'lfBrtip',
        language: {
            info: i18n.showing_x_to_y_rows,
            search: i18n.search,
            infoFiltered: "",
            paginate: {
                previous: '&lt;',
                next: '&gt;',
                first: '«',
                last: '»'
            },
            emptyTable: i18n.createEndpointFirst
        },
        buttons: {
            buttons: [
                {
                    text: '<i class="fas fa-plus"></i>',
                    className: 'btn-link',
                    action: function (e, dt, node, config) {
                        $('#add-recipient-modal').modal('show');
                    }
                }
            ],
            dom: {
                button: {
                    className: 'btn btn-link'
                },
                container: {
                    className: 'float-right'
                }
            }
        },
        ajax: {
            url: `${http_prefix}/lua/get_recipients_endpoint.lua`,
            type: 'GET',
            dataSrc: ''
        },
        columns: [
            {
                data: 'recipient_name'
            },
            {
                data: 'endpoint_conf.endpoint_conf_name'
            },
            {
                targets: -1,
                className: 'text-center',
                data: null,
                render: function () {
                    return (`
                        <a data-toggle='modal' href='#edit-recipient-modal' class="badge badge-info">${i18n.edit}</a>
                        <a data-toggle='modal' href='#remove-recipient-modal' class="badge badge-danger">${i18n.remove}</a>
                    `);
                }
            }
        ]
    });

    /* bind edit recipient event */
    $(`table#recipient-list`).on('click', `a[href='#edit-recipient-modal']`, function (e) {

        const rowData = $recipientsTable.row($(this).parent()).data();

        $('#edit-recipient-modal form').modalHandler({
            method: 'post',
            csrf: pageCsrf,
            endpoint: `${http_prefix}/lua/edit_notification_recipient.lua`,
            beforeSumbit: function () {
                const data = makeFormData(`#edit-recipient-modal form`);
                data.action = 'edit';
                return data;
            },
            loadFormData: function () {
                return rowData;
            },
            onModalInit: function (data) {
                /* load the right template from templates */
                $(`#edit-recipient-modal form .recipient-template-container`)
                    .empty().append(loadTemplate(data.endpoint_conf.endpoint_key));
                /* load the values inside the template */
                $(`#edit-recipient-modal form [name='name']`).val(data.recipient_name);
                $(`#edit-recipient-modal form .recipient-template-container [name]`).each(function(i, input) {
                    $(this).val(data.recipient_params[$(this).attr('name')]);
                });
            },
            onSubmitSuccess: function (response) {
                if (response.result.status == "OK") {
                    $(`#edit-recipient-modal`).modal('hide');
                    $recipientsTable.ajax.reload();
                }
            }
        });
    });

    /* bind add endpoint event */
    $(`#add-recipient-modal form`).modalHandler({
        method: 'post',
        endpoint: `${http_prefix}/lua/edit_notification_recipient.lua`,
        csrf: pageCsrf,
        resetAfterSubmit: false,
        beforeSumbit: function () {

            $(`#add-recipient-modal form button[type='submit']`).click(function() {
                $(`#add-recipient-modal form span.invalid-feedback`).hide();
            });

            const data = makeFormData(`#add-recipient-modal form`);
            data.action = 'add';
            return data;
        },
        onModalInit: function() {
            createTemplateOnSelect(`#add-recipient-modal`);
        },
        onSubmitSuccess: function (response) {
            if (response.result.status == "OK") {
                $(`#add-recipient-modal`).modal('hide');
                $(`#add-recipient-modal form .recipient-template-container`).hide();
                cleanForm(`#add-recipient-modal form`);
                $recipientsTable.ajax.reload();
                return;
            }

            if (response.result.error) {
                const localizedString = i18n[response.result.error.type];
                $(`#add-recipient-modal form span.invalid-feedback`).text(localizedString).show();
            }
        }
    });

    /* bind remove endpoint event */
    $(`table#recipient-list`).on('click', `a[href='#remove-recipient-modal']`, function (e) {

        const rowData = $recipientsTable.row($(this).parent()).data();

        $(`#remove-recipient-modal form`).modalHandler({
            method: 'post',
            csrf: pageCsrf,
            endpoint: `${http_prefix}/lua/edit_notification_recipient.lua`,
            beforeSumbit: () => {
                return {
                    action: 'remove',
                    recipient_name: rowData.recipient_name
                }
            },
            onSubmitSuccess: function (response) {
                if (response.result.status == "OK") {
                    $(`#remove-recipient-modal`).modal('hide');
                    $recipientsTable.ajax.reload();
                }
            }
        });
    });


});